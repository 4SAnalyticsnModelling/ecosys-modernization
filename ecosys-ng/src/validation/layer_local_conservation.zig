const std = @import("std");
const inventory = @import("landscape_mass_inventory.zig");
const hourly = @import("hourly_cell_conservation.zig");
const hydrology = @import("../transport/hydrology.zig");
const solute_species = @import("../soil/solute/transport_species.zig");
const surface_aqueous = @import("../surface/aqueous_runoff_transport.zig");
const gas_transport = @import("../soil/gas/transport.zig");
const gas_transport_step = @import("../soil/gas/transport_step.zig");
const organic_transport = @import("../soil/organic/transport.zig");
const mineral_nitrogen_transport = @import("../soil/biogeochemistry/mineral_nitrogen_transport.zig");
const snow = @import("../soil/solute/snow_solute_transport.zig");
const snow_relayering = @import("../soil/water/snow_relayering.zig");
const ice_units = @import("../core/ice_units.zig");
const canopy_conservation = @import("../canopy/energy/conservation_sidecar.zig");
const atmospheric_local = @import("../atmosphere/local_conservation_sidecar.zig");
const suspended = @import("../erosion/suspended_constituents.zig");
const eroded_constituents = @import("../erosion/eroded_constituents.zig");
const organic_state = @import("../soil/organic/initialization.zig");
const pond_conservation = @import("../surface/pond_conservation_sidecar.zig");
const fertilizer_dispatch = @import("../management/fertilizer_management_dispatch.zig");
const grazing_manure = @import("../management/grazing_manure.zig");
const root_atmosphere = @import("../plant/root/atmosphere_gas_state_update.zig");
const root_withdrawal = @import("../plant/root/gas_withdrawal_state_update.zig");
const plant_internal = @import("../plant/accounting/internal_root_shoot_activity.zig");
const soil_microbial_mixing = @import("../soil/microbial/layer_mixing.zig");
const surface_microbial_mixing = @import("../surface/topsoil_microbial_mixing.zig");
const surface_organic_decomposition = @import("../surface/organic_decomposition_step.zig");
const surface_microbial_turnover = @import("../surface/microbial_turnover_step.zig");
const surface_microbial_respiration = @import("../surface/microbial_respiration_step.zig");
const surface_topsoil_exchange = @import("../surface/topsoil_mineral_exchange_step.zig");
const surface_autotrophic = @import("../surface/autotrophic_complex_step.zig");
const soil_oxygen_allocation = @import("../soil/gas/oxygen_allocation.zig");
const soil_respiration_products = @import("../soil/microbial/respiration_products_step.zig");
const soil_methane = @import("../soil/gas/methane_step.zig");
const surface_oxygen = @import("../surface/microbial_oxygen_driver.zig");
const organic_fire = @import("../soil/biogeochemistry/organic_matter_fire_exchange.zig");
const soil_relayering_activity = @import("../soil/profile/relayering_activity.zig");
const tillage_activity = @import("../redistribution/tillage/activity.zig");
const chemistry_water_rebase = @import("../soil/chemistry/water_carrier_rebase.zig");

// The runtime conservation traversals below intentionally replace reflected
// `inline for` expansion. Keep this guard next to the imports so a future enum
// reordering or explicit discriminant cannot silently change traversal order.
comptime {
    for (@typeInfo(snow.Species).@"enum".fields, 0..) |field, index| {
        if (field.value != index) @compileError("snow.Species must remain contiguous and declaration ordered");
    }
    for (@typeInfo(snow.SaltSpecies).@"enum".fields, 0..) |field, index| {
        if (field.value != index) @compileError("snow.SaltSpecies must remain contiguous and declaration ordered");
    }
}

// Source-order provenance for this control-volume split:
//
// * `ecosys_f77/redist.f:3373-3388` constructs each soil-layer water/heat
//   change as incoming face minus outgoing face, and `:5947-6003` applies
//   those layer-local terms together with infiltration, root uptake and other
//   process sources. A whole-column check loses that identity.
// * `ecosys_f77/redist.f:3447-3452` does the same incoming-minus-outgoing
//   construction for transported mineral N; `trnsfr.f:6989-6994` preserves
//   the same layer index before state update.
// * `ecosys_f77/redist.f:2423-2434` constructs each snow-layer phase and heat
//   change from adjacent-layer fluxes; `:4259-4281` separately transfers the
//   snow-surface exchange into litter.
// * `ecosys_f77/redist.f:7405-7714` relayers fixed snow-layer slots: the exact
//   same fraction of all phases, sensible heat, primary solutes, and dynamic
//   salts is added to the adjacent recipient and removed from its donor.
// * `ecosys_f77/uptake.f:1335-1341` retains root-water uptake by soil layer;
//   `redist.f:5928-6003` consumes its TUPWTR/TUPHT layer totals.
//
// Hence soil layers, snow layers, litter/surface and canopy are independent
// acceptance scopes. Their later column/domain reductions remain diagnostics,
// never substitutes for the local gates below.

/// Independently accepted control volumes. Soil and snow remain layer-local;
/// surface and canopy remain separate cell scopes. This is the minimum layout
/// that prevents equal-and-opposite defects in one vertical column from being
/// hidden by the existing horizontal-cell reduction.
pub const ScopeKind = enum(u8) {
    soil_layer,
    snow_layer,
    surface,
    canopy,
};

pub const ScopeAddress = struct {
    kind: ScopeKind,
    cell: usize,
    layer: usize = 0,
};

/// Static production contract for activity that can change or cross an
/// independently accepted soil-layer, snow-layer, surface, or canopy control
/// volume. A zero runtime value does not waive its producer wiring.
pub const ActivityFamily = enum(u8) {
    soil_transport_faces,
    soil_gas_bubbling,
    snow_transport_faces,
    snow_surface_soil_transfer,
    snow_drift,
    surface_runoff,
    litter_soil_water_heat_solutes,
    atmospheric_water_heat_solutes,
    soil_external_boundaries,
    canopy_surface_water_heat,
    sediment_erosion_settling,
    soil_layer_redistribution,
    surface_soil_tillage,
    plant_litterfall,
    plant_internal_root_shoot,
    root_water_heat_uptake,
    root_gas_exchange,
    plant_atmosphere,
    soil_surface_gas_atmosphere,
    management_fertilizer_irrigation,
    management_fire_harvest,
    biogeochemical_internal,
    charcoal_exchange_capacity,
};

fn activityMask(comptime values: anytype) u32 {
    var result: u32 = 0;
    inline for (values) |value| result |= @as(u32, 1) << @intFromEnum(value);
    return result;
}

pub const production_required_activity: u32 = activityMask(std.enums.values(ActivityFamily));

/// Updated only after a family has exact accepted producer outputs, atomic
/// donor/recipient publication, and a focused local-closure test. The
/// authoritative storage side is already complete because every reconstruction
/// must pass the exact scope-to-canonical-cell partition identity.
pub const production_bound_activity: u32 = activityMask(.{
    ActivityFamily.soil_transport_faces,
    // REDIST LL=MIN(L,LG) can relocate bubbles across several layers without
    // traversing a transport face. Its accepted source/receiver sidecar is a
    // distinct local transfer family.
    ActivityFamily.soil_gas_bubbling,
    ActivityFamily.snow_transport_faces,
    ActivityFamily.snow_surface_soil_transfer,
    ActivityFamily.snow_drift,
    ActivityFamily.surface_runoff,
    // WATSUB FLWR/HFLWR and TRNSFR solute/organic/mineral transfers cross
    // the independently accepted litter and topsoil scopes even though they
    // remain internal to their shared horizontal column.
    ActivityFamily.litter_soil_water_heat_solutes,
    ActivityFamily.atmospheric_water_heat_solutes,
    ActivityFamily.soil_external_boundaries,
    ActivityFamily.canopy_surface_water_heat,
    ActivityFamily.sediment_erosion_settling,
    // REDIST publishes attempt-atomic canonical gross transfers at each live
    // adjacent-layer face; end-of-hour geometry consumes them exactly once.
    ActivityFamily.soil_layer_redistribution,
    // REDIST tillage publishes the exact ordered m*TI*FI gross matrix plus
    // the distinct surface-incorporation path from its private transaction.
    ActivityFamily.surface_soil_tillage,
    // Irrigation is routed once by atmospheric_water_heat_solutes to its
    // actual snow/surface/topsoil receiver; this family owns only the exact
    // fertilizer sidecar and must never duplicate that irrigation activity.
    ActivityFamily.management_fertilizer_irrigation,
    ActivityFamily.plant_litterfall,
    // The producer-owned direction-separated sidecar is populated by the
    // live GROSUB shoot/root exchange and consumed once by hourly_vegetation.
    ActivityFamily.plant_internal_root_shoot,
    ActivityFamily.root_water_heat_uptake,
    ActivityFamily.root_gas_exchange,
    ActivityFamily.plant_atmosphere,
    ActivityFamily.soil_surface_gas_atmosphere,
    // Harvest, manure and fire publish their accepted canopy/surface/soil
    // operands through the dedicated accumulators below before hour commit.
    ActivityFamily.management_fire_harvest,
    // Soil/surface microbial mixing, reaction sinks/sources and organic
    // returns are retained from output-only producer sidecars in the live
    // biogeochemistry batches.
    ActivityFamily.biogeochemical_internal,
    ActivityFamily.charcoal_exchange_capacity,
});

pub fn productionCoverageComplete() bool {
    return production_bound_activity == production_required_activity;
}

pub fn requireProductionCoverage() !void {
    if (!productionCoverageComplete())
        return error.LayerLocalConservationCoverageIncomplete;
}

pub const Layout = struct {
    cell_count: usize,
    soil_layer_capacity: usize,
    snow_layer_capacity: usize,

    pub fn init(
        cell_count: usize,
        soil_layer_capacity: usize,
        snow_layer_capacity: usize,
    ) !Layout {
        if (cell_count == 0 or soil_layer_capacity == 0 or snow_layer_capacity == 0)
            return error.InvalidLayerConservationLayout;
        const result: Layout = .{
            .cell_count = cell_count,
            .soil_layer_capacity = soil_layer_capacity,
            .snow_layer_capacity = snow_layer_capacity,
        };
        _ = try result.scopeCount();
        return result;
    }

    pub fn soilCount(self: Layout) !usize {
        return std.math.mul(usize, self.cell_count, self.soil_layer_capacity);
    }

    pub fn snowCount(self: Layout) !usize {
        return std.math.mul(usize, self.cell_count, self.snow_layer_capacity);
    }

    pub fn scopeCount(self: Layout) !usize {
        const layer_count = try std.math.add(usize, try self.soilCount(), try self.snowCount());
        return std.math.add(usize, layer_count, try std.math.mul(usize, self.cell_count, 2));
    }

    pub fn index(self: Layout, scope_address: ScopeAddress) !usize {
        if (scope_address.cell >= self.cell_count) return error.LayerConservationScopeOutOfBounds;
        const soil_count = try self.soilCount();
        const snow_count = try self.snowCount();
        return switch (scope_address.kind) {
            .soil_layer => blk: {
                if (scope_address.layer >= self.soil_layer_capacity)
                    return error.LayerConservationScopeOutOfBounds;
                break :blk scope_address.cell * self.soil_layer_capacity + scope_address.layer;
            },
            .snow_layer => blk: {
                if (scope_address.layer >= self.snow_layer_capacity)
                    return error.LayerConservationScopeOutOfBounds;
                break :blk soil_count + scope_address.cell * self.snow_layer_capacity + scope_address.layer;
            },
            .surface => soil_count + snow_count + scope_address.cell,
            .canopy => soil_count + snow_count + self.cell_count + scope_address.cell,
        };
    }

    pub fn address(self: Layout, scope: usize) !ScopeAddress {
        const soil_count = try self.soilCount();
        const snow_count = try self.snowCount();
        if (scope < soil_count) return .{
            .kind = .soil_layer,
            .cell = scope / self.soil_layer_capacity,
            .layer = scope % self.soil_layer_capacity,
        };
        if (scope < soil_count + snow_count) {
            const local = scope - soil_count;
            return .{
                .kind = .snow_layer,
                .cell = local / self.snow_layer_capacity,
                .layer = local % self.snow_layer_capacity,
            };
        }
        if (scope < soil_count + snow_count + self.cell_count) return .{
            .kind = .surface,
            .cell = scope - soil_count - snow_count,
        };
        if (scope < try self.scopeCount()) return .{
            .kind = .canopy,
            .cell = scope - soil_count - snow_count - self.cell_count,
        };
        return error.LayerConservationScopeOutOfBounds;
    }
};

/// Direction-separated activity for every local control volume. A transfer is
/// always written twice: donor output and recipient input. No signed net is
/// retained, so a later reduction cannot erase throughput or reverse a sign.
pub const Ledger = struct {
    allocator: std.mem.Allocator,
    layout: Layout,
    activity: []hourly.BoundaryActivity,
    /// Number of accepted binary64 water-carrier publications in each local
    /// control volume. Counts are schedule-private until the complete coupled
    /// attempt succeeds and are consumed exactly once below.
    water_storage_update_operation_count_by_scope: []u16 = &.{},
    /// Producer-certified arithmetic bounds that cannot be represented by a
    /// nominal owner count (notably Richards and post-Richards layer gates).
    /// Attempt publication is transactional and consumption is exactly once.
    pending_water_storage_roundoff_allowance_m3_by_scope: []f64 = &.{},
    /// Transaction-private producer certificates for accepted heat-storage
    /// arithmetic. Only soil scopes may receive WATSUB spatial-heat bounds.
    pending_heat_storage_roundoff_allowance_megajoules_by_scope: []f64 = &.{},

    pub fn init(allocator: std.mem.Allocator, layout: Layout) !Ledger {
        const scope_count = try layout.scopeCount();
        const activity = try allocator.alloc(hourly.BoundaryActivity, scope_count);
        errdefer allocator.free(activity);
        const operation_count = try allocator.alloc(u16, scope_count);
        errdefer allocator.free(operation_count);
        const pending_roundoff = try allocator.alloc(f64, scope_count);
        errdefer allocator.free(pending_roundoff);
        const pending_heat_roundoff = try allocator.alloc(f64, scope_count);
        @memset(activity, .{});
        @memset(operation_count, 0);
        @memset(pending_roundoff, 0);
        @memset(pending_heat_roundoff, 0);
        return .{
            .allocator = allocator,
            .layout = layout,
            .activity = activity,
            .water_storage_update_operation_count_by_scope = operation_count,
            .pending_water_storage_roundoff_allowance_m3_by_scope = pending_roundoff,
            .pending_heat_storage_roundoff_allowance_megajoules_by_scope = pending_heat_roundoff,
        };
    }

    pub fn deinit(self: *Ledger) void {
        self.allocator.free(self.pending_heat_storage_roundoff_allowance_megajoules_by_scope);
        self.allocator.free(self.pending_water_storage_roundoff_allowance_m3_by_scope);
        self.allocator.free(self.water_storage_update_operation_count_by_scope);
        self.allocator.free(self.activity);
        self.* = undefined;
    }

    pub fn reset(self: *Ledger) void {
        @memset(self.activity, .{});
        @memset(self.water_storage_update_operation_count_by_scope, 0);
        @memset(self.pending_water_storage_roundoff_allowance_m3_by_scope, 0);
        @memset(self.pending_heat_storage_roundoff_allowance_megajoules_by_scope, 0);
    }

    pub fn accumulate(self: *Ledger, address: ScopeAddress, fragment: hourly.BoundaryActivity) !void {
        const scope = try self.layout.index(address);
        self.activity[scope] = try hourly.addActivities(self.activity[scope], fragment);
    }

    pub fn accumulateTransfer(
        self: *Ledger,
        donor: ScopeAddress,
        recipient: ScopeAddress,
        transfer: hourly.IntercellTransfer,
    ) !void {
        const donor_scope = try self.layout.index(donor);
        const recipient_scope = try self.layout.index(recipient);
        if (donor_scope == recipient_scope) return error.InvalidLayerConservationTransfer;
        try validateTransfer(transfer);
        const donor_next = try hourly.addActivities(self.activity[donor_scope], transferActivity(transfer, .output));
        const recipient_next = try hourly.addActivities(self.activity[recipient_scope], transferActivity(transfer, .input));
        // Publish only after both sides validate. Failed attempts leave no
        // one-sided scientific accounting side effect.
        self.activity[donor_scope] = donor_next;
        self.activity[recipient_scope] = recipient_next;
    }
};

fn roundUpProduct(left: f64, right: f64) !f64 {
    if (!std.math.isFinite(left) or left < 0 or
        !std.math.isFinite(right) or right <= 0)
        return error.InvalidChemistryRebaseArithmeticProvenance;
    var result = left * right;
    if (!std.math.isFinite(result))
        return error.InvalidChemistryRebaseArithmeticProvenance;
    if (result > 0)
        result = std.math.nextAfter(f64, result, std.math.inf(f64));
    if (!std.math.isFinite(result))
        return error.InvalidChemistryRebaseArithmeticProvenance;
    return result;
}

noinline fn chemistryRebaseRoundoffActivity(
    allowance: chemistry_water_rebase.RoundoffAllowance,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !hourly.BoundaryActivity {
    try allowance.validate();
    return .{
        .carbon_storage_update_roundoff_allowance_g = @max(
            allowance.carbon_g,
            try roundUpProduct(allowance.carbon_mol, carbon_g_per_mol),
        ),
        .phosphorus_storage_update_roundoff_allowance_g = @max(
            allowance.phosphorus_g,
            try roundUpProduct(allowance.phosphorus_mol, phosphorus_g_per_mol),
        ),
        .aluminum_storage_update_roundoff_allowance_mol = allowance.aluminum_mol,
        .iron_storage_update_roundoff_allowance_mol = allowance.iron_mol,
        .calcium_storage_update_roundoff_allowance_mol = allowance.calcium_mol,
        .magnesium_storage_update_roundoff_allowance_mol = allowance.magnesium_mol,
        .sodium_storage_update_roundoff_allowance_mol = allowance.sodium_mol,
        .potassium_storage_update_roundoff_allowance_mol = allowance.potassium_mol,
        .sulfur_storage_update_roundoff_allowance_mol = allowance.sulfur_mol,
        .silicon_storage_update_roundoff_allowance_mol = allowance.silicon_mol,
    };
}

noinline fn surfaceChemistryRebaseRoundoffActivity(
    allowance: chemistry_water_rebase.RoundoffAllowance,
    carbon_g_per_mol: f64,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !hourly.BoundaryActivity {
    var result = try chemistryRebaseRoundoffActivity(
        allowance,
        carbon_g_per_mol,
        phosphorus_g_per_mol,
    );
    result.nitrogen_storage_update_roundoff_allowance_g = @max(
        allowance.nitrogen_g,
        try roundUpProduct(allowance.nitrogen_mol, nitrogen_g_per_mol),
    );
    result.chloride_storage_update_roundoff_allowance_mol = allowance.chloride_mol;
    return result;
}

/// Publishes certified, attempt-owned concentration-carrier rebase error to
/// the matching soil-layer scopes and their cell reductions. All candidates
/// are validated first; a failed attempt therefore changes neither ledger.
/// Physical tolerances and directional material activity are untouched.
pub fn accumulateAcceptedChemistryRebaseRoundoff(
    cell_ledger: *hourly.BoundaryLedger,
    layer_ledger: *Ledger,
    allowance_by_flat_soil_layer: []const chemistry_water_rebase.RoundoffAllowance,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !void {
    const layout = layer_ledger.layout;
    const expected_layers = try std.math.mul(
        usize,
        layout.cell_count,
        layout.soil_layer_capacity,
    );
    if (allowance_by_flat_soil_layer.len != expected_layers or
        cell_ledger.cells.len != layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;

    const cell_allowance = try layer_ledger.allocator.alloc(
        chemistry_water_rebase.RoundoffAllowance,
        layout.cell_count,
    );
    defer layer_ledger.allocator.free(cell_allowance);
    @memset(cell_allowance, .{});

    // Preflight local conversion/reduction and both destination additions.
    for (allowance_by_flat_soil_layer, 0..) |allowance, flat_layer| {
        const cell = flat_layer / layout.soil_layer_capacity;
        const local_layer = flat_layer % layout.soil_layer_capacity;
        try cell_allowance[cell].add(allowance);
        const scope = try layout.index(.{
            .kind = .soil_layer,
            .cell = cell,
            .layer = local_layer,
        });
        _ = try hourly.addActivities(
            layer_ledger.activity[scope],
            try chemistryRebaseRoundoffActivity(
                allowance,
                carbon_g_per_mol,
                phosphorus_g_per_mol,
            ),
        );
    }
    for (cell_ledger.cells, cell_allowance) |current, allowance|
        _ = try hourly.addActivities(
            current,
            try chemistryRebaseRoundoffActivity(
                allowance,
                carbon_g_per_mol,
                phosphorus_g_per_mol,
            ),
        );

    // The serial hourly ledgers cannot change between preflight and commit.
    for (allowance_by_flat_soil_layer, 0..) |allowance, flat_layer| {
        const cell = flat_layer / layout.soil_layer_capacity;
        const local_layer = flat_layer % layout.soil_layer_capacity;
        const scope = layout.index(.{
            .kind = .soil_layer,
            .cell = cell,
            .layer = local_layer,
        }) catch unreachable;
        layer_ledger.activity[scope] = hourly.addActivities(
            layer_ledger.activity[scope],
            chemistryRebaseRoundoffActivity(
                allowance,
                carbon_g_per_mol,
                phosphorus_g_per_mol,
            ) catch unreachable,
        ) catch unreachable;
    }
    for (cell_ledger.cells, cell_allowance) |*current, allowance|
        current.* = hourly.addActivities(
            current.*,
            chemistryRebaseRoundoffActivity(
                allowance,
                carbon_g_per_mol,
                phosphorus_g_per_mol,
            ) catch unreachable,
        ) catch unreachable;
}

/// Publishes certified surface litter concentration-carrier arithmetic to the
/// horizontal-cell and matching surface local scopes. The source allowance is
/// attempt-private; this routine validates both destinations before either is
/// changed, so rejected recovery schedules leave no accounting side effects.
pub noinline fn accumulateAcceptedSurfaceChemistryRebaseRoundoff(
    cell_ledger: *hourly.BoundaryLedger,
    layer_ledger: *Ledger,
    allowance_by_cell: []const chemistry_water_rebase.RoundoffAllowance,
    carbon_g_per_mol: f64,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !void {
    const layout = layer_ledger.layout;
    if (allowance_by_cell.len != layout.cell_count or
        cell_ledger.cells.len != layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;

    for (allowance_by_cell, 0..) |allowance, cell| {
        const fragment = try surfaceChemistryRebaseRoundoffActivity(
            allowance,
            carbon_g_per_mol,
            nitrogen_g_per_mol,
            phosphorus_g_per_mol,
        );
        const scope = try layout.index(.{ .kind = .surface, .cell = cell });
        _ = try hourly.addActivities(layer_ledger.activity[scope], fragment);
        _ = try hourly.addActivities(cell_ledger.cells[cell], fragment);
    }

    for (allowance_by_cell, 0..) |allowance, cell| {
        const fragment = surfaceChemistryRebaseRoundoffActivity(
            allowance,
            carbon_g_per_mol,
            nitrogen_g_per_mol,
            phosphorus_g_per_mol,
        ) catch unreachable;
        const scope = layout.index(.{ .kind = .surface, .cell = cell }) catch unreachable;
        layer_ledger.activity[scope] = hourly.addActivities(
            layer_ledger.activity[scope],
            fragment,
        ) catch unreachable;
        cell_ledger.cells[cell] = hourly.addActivities(
            cell_ledger.cells[cell],
            fragment,
        ) catch unreachable;
    }
}

fn waterStorageUpdateRoundoffAllowance(
    before: inventory.Storage,
    after: inventory.Storage,
    activity: hourly.BoundaryActivity,
    operation_count: u16,
) !f64 {
    if (operation_count <= 1) return 0;
    try before.validate();
    try after.validate();
    const scaled_epsilon = @as(f64, @floatFromInt(operation_count)) *
        std.math.floatEps(f64);
    if (!std.math.isFinite(scaled_epsilon) or scaled_epsilon >= 1)
        return error.InvalidWaterStorageUpdateArithmeticProvenance;
    // Higham's gamma_n bound for the accepted source-ordered sequence. The
    // standing term covers the carried state and the direction-separated
    // throughput covers every local water increment without cancellation.
    const magnitude = @max(@abs(before.water_m3), @abs(after.water_m3)) +
        activity.water_input_m3 + activity.water_output_m3;
    const allowance = scaled_epsilon / (1 - scaled_epsilon) * magnitude;
    if (!std.math.isFinite(magnitude) or !std.math.isFinite(allowance) or allowance < 0)
        return error.InvalidWaterStorageUpdateArithmeticProvenance;
    return allowance;
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

/// Converts the exact successfully accepted water-carrier publication counts into explicit
/// per-scope binary64 forward-error provenance. Only WATSUB-owned soil, snow,
/// and surface scopes are included. The cell bound is the non-cancelling sum
/// of those local bounds; canopy storage cannot inflate it. Publication is
/// atomic and operation counts are consumed exactly once.
pub fn accumulateAcceptedWaterStorageUpdateRoundoff(
    cell_ledger: *hourly.BoundaryLedger,
    layer_ledger: *Ledger,
    storage_before: []const inventory.Storage,
    storage_after: []const inventory.Storage,
) !void {
    const scope_count = try layer_ledger.layout.scopeCount();
    if (storage_before.len != scope_count or storage_after.len != scope_count or
        layer_ledger.activity.len != scope_count or
        layer_ledger.water_storage_update_operation_count_by_scope.len != scope_count or
        layer_ledger.pending_water_storage_roundoff_allowance_m3_by_scope.len != scope_count or
        cell_ledger.cells.len != layer_ledger.layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    var saw_operation = false;

    const cell_allowance = try layer_ledger.allocator.alloc(
        f64,
        layer_ledger.layout.cell_count,
    );
    defer layer_ledger.allocator.free(cell_allowance);
    @memset(cell_allowance, 0);

    // First pass validates every candidate and reduces local bounds without
    // mutating either ledger, preserving outer-hour rollback atomicity.
    for (0..scope_count) |scope| {
        const address = try layer_ledger.layout.address(scope);
        const operation_count = layer_ledger.water_storage_update_operation_count_by_scope[scope];
        const producer_allowance = layer_ledger.pending_water_storage_roundoff_allowance_m3_by_scope[scope];
        if (!std.math.isFinite(producer_allowance) or producer_allowance < 0)
            return error.InvalidWaterStorageUpdateArithmeticProvenance;
        if (address.kind == .canopy) {
            if (operation_count != 0 or producer_allowance != 0)
                return error.InvalidWaterStorageUpdateArithmeticProvenance;
            continue;
        }
        saw_operation = saw_operation or operation_count != 0 or producer_allowance != 0;
        if (layer_ledger.activity[scope].water_storage_update_roundoff_allowance_m3 != 0)
            return error.DuplicateWaterStorageUpdateArithmeticProvenance;
        const allowance = try addWaterStorageRoundoffUpward(
            try waterStorageUpdateRoundoffAllowance(
                storage_before[scope],
                storage_after[scope],
                layer_ledger.activity[scope],
                operation_count,
            ),
            producer_allowance,
        );
        cell_allowance[address.cell] = try addWaterStorageRoundoffUpward(
            cell_allowance[address.cell],
            allowance,
        );
        _ = try hourly.addActivities(layer_ledger.activity[scope], .{
            .water_storage_update_roundoff_allowance_m3 = allowance,
        });
    }
    if (!saw_operation) return error.InvalidWaterStorageUpdateArithmeticProvenance;
    for (cell_ledger.cells, cell_allowance) |current, allowance| {
        if (current.water_storage_update_roundoff_allowance_m3 != 0)
            return error.DuplicateWaterStorageUpdateArithmeticProvenance;
        _ = try hourly.addActivities(current, .{
            .water_storage_update_roundoff_allowance_m3 = allowance,
        });
    }

    // Every operation below was preflighted above and cannot fail without a
    // concurrent mutation; hourly ledgers are serial transaction owners.
    for (0..scope_count) |scope| {
        const address = layer_ledger.layout.address(scope) catch unreachable;
        if (address.kind == .canopy) continue;
        const operation_count = layer_ledger.water_storage_update_operation_count_by_scope[scope];
        const allowance = addWaterStorageRoundoffUpward(
            waterStorageUpdateRoundoffAllowance(
                storage_before[scope],
                storage_after[scope],
                layer_ledger.activity[scope],
                operation_count,
            ) catch unreachable,
            layer_ledger.pending_water_storage_roundoff_allowance_m3_by_scope[scope],
        ) catch unreachable;
        layer_ledger.activity[scope] = hourly.addActivities(
            layer_ledger.activity[scope],
            .{ .water_storage_update_roundoff_allowance_m3 = allowance },
        ) catch unreachable;
    }
    for (cell_ledger.cells, cell_allowance) |*current, allowance|
        current.* = hourly.addActivities(current.*, .{
            .water_storage_update_roundoff_allowance_m3 = allowance,
        }) catch unreachable;
    @memset(layer_ledger.water_storage_update_operation_count_by_scope, 0);
    @memset(layer_ledger.pending_water_storage_roundoff_allowance_m3_by_scope, 0);
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

/// Publishes accepted WATSUB spatial-heat arithmetic certificates at the
/// originating soil layer and at its non-cancelling horizontal-cell reduction.
/// The phase solver's independent energy gate runs before these values exist,
/// so nonlinear endpoint error can never enter this provenance lane.
pub fn accumulateAcceptedHeatStorageUpdateRoundoff(
    cell_ledger: *hourly.BoundaryLedger,
    layer_ledger: *Ledger,
) !void {
    const scope_count = try layer_ledger.layout.scopeCount();
    if (layer_ledger.activity.len != scope_count or
        layer_ledger.pending_heat_storage_roundoff_allowance_megajoules_by_scope.len != scope_count or
        cell_ledger.cells.len != layer_ledger.layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    const cell_allowance = try layer_ledger.allocator.alloc(
        f64,
        layer_ledger.layout.cell_count,
    );
    defer layer_ledger.allocator.free(cell_allowance);
    @memset(cell_allowance, 0);
    var saw_producer = false;

    // Preflight every local and reduced publication before either ledger is
    // mutated. Inactive/snow/surface/canopy scopes may not borrow a soil bound.
    for (0..scope_count) |scope| {
        const address = try layer_ledger.layout.address(scope);
        const allowance = layer_ledger.pending_heat_storage_roundoff_allowance_megajoules_by_scope[scope];
        if (!std.math.isFinite(allowance) or allowance < 0)
            return error.InvalidHeatStorageUpdateArithmeticProvenance;
        if (address.kind != .soil_layer) {
            if (allowance != 0)
                return error.InvalidHeatStorageUpdateArithmeticProvenance;
            continue;
        }
        saw_producer = saw_producer or allowance != 0;
        if (layer_ledger.activity[scope].heat_storage_update_roundoff_allowance_megajoules != 0)
            return error.DuplicateHeatStorageUpdateArithmeticProvenance;
        cell_allowance[address.cell] = try addHeatStorageRoundoffUpward(
            cell_allowance[address.cell],
            allowance,
        );
        _ = try hourly.addActivities(layer_ledger.activity[scope], .{
            .heat_storage_update_roundoff_allowance_megajoules = allowance,
        });
    }
    if (!saw_producer) return error.InvalidHeatStorageUpdateArithmeticProvenance;
    for (cell_ledger.cells, cell_allowance) |current, allowance| {
        if (current.heat_storage_update_roundoff_allowance_megajoules != 0)
            return error.DuplicateHeatStorageUpdateArithmeticProvenance;
        _ = try hourly.addActivities(current, .{
            .heat_storage_update_roundoff_allowance_megajoules = allowance,
        });
    }

    for (0..scope_count) |scope| {
        const address = layer_ledger.layout.address(scope) catch unreachable;
        if (address.kind != .soil_layer) continue;
        const allowance = layer_ledger.pending_heat_storage_roundoff_allowance_megajoules_by_scope[scope];
        layer_ledger.activity[scope] = hourly.addActivities(
            layer_ledger.activity[scope],
            .{ .heat_storage_update_roundoff_allowance_megajoules = allowance },
        ) catch unreachable;
    }
    for (cell_ledger.cells, cell_allowance) |*current, allowance|
        current.* = hourly.addActivities(current.*, .{
            .heat_storage_update_roundoff_allowance_megajoules = allowance,
        }) catch unreachable;
    @memset(layer_ledger.pending_heat_storage_roundoff_allowance_megajoules_by_scope, 0);
}

/// Books REDIST's accepted gross transfers at their exact adjacent-layer
/// faces. Material and enthalpy are deliberately published separately:
/// frozen material can carry negative referenced enthalpy, in which case the
/// material moves donor-to-recipient while the heat ledger moves oppositely.
/// The producer sidecar is attempt-atomic; this adapter is atomic as well.
pub fn accumulateSoilRelayeringActivity(
    ledger: *Ledger,
    sidecar: *const soil_relayering_activity.Sidecar,
    first_active_soil_layer: []const usize,
    active_soil_layer_count: []const usize,
) !void {
    try sidecar.validateLayout(ledger.layout.cell_count, ledger.layout.soil_layer_capacity);
    if (sidecar.attempt_active or
        first_active_soil_layer.len != ledger.layout.cell_count or
        active_soil_layer_count.len != ledger.layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{
        .allocator = ledger.allocator,
        .layout = ledger.layout,
        .activity = candidate_values,
    };
    const cap = ledger.layout.soil_layer_capacity;
    for (0..ledger.layout.cell_count) |cell| {
        const first = first_active_soil_layer[cell];
        const active = active_soil_layer_count[cell];
        if (first > cap or active > cap - first)
            return error.InvalidActiveSoilLayerCount;
        for (0..cap) |upper| {
            const record = try sidecar.record(cell, upper);
            try record.transfer.validate();
            inline for (std.meta.fields(inventory.Storage)) |field| {
                const value = @field(record.transfer, field.name);
                if (value < 0) return error.InvalidLayerConservationActivity;
            }
            const material = try storageToIntercellTransfer(.{
                .water_m3 = record.transfer.water_m3,
                .oxygen_g = record.transfer.oxygen_g,
                .hydrogen_g = record.transfer.hydrogen_g,
                .residue_carbon_g = record.transfer.residue_carbon_g,
                .organic_carbon_g = record.transfer.organic_carbon_g,
                .carbon_dioxide_carbon_g = record.transfer.carbon_dioxide_carbon_g,
                .plant_carbon_g = record.transfer.plant_carbon_g,
                .plant_nitrogen_g = record.transfer.plant_nitrogen_g,
                .plant_phosphorus_g = record.transfer.plant_phosphorus_g,
                .residue_nitrogen_g = record.transfer.residue_nitrogen_g,
                .organic_nitrogen_g = record.transfer.organic_nitrogen_g,
                .dinitrogen_nitrogen_g = record.transfer.dinitrogen_nitrogen_g,
                .ammonium_nitrogen_g = record.transfer.ammonium_nitrogen_g,
                .nitrate_nitrogen_g = record.transfer.nitrate_nitrogen_g,
                .residue_phosphorus_g = record.transfer.residue_phosphorus_g,
                .organic_phosphorus_g = record.transfer.organic_phosphorus_g,
                .phosphate_phosphorus_g = record.transfer.phosphate_phosphorus_g,
                .aluminum_mol = record.transfer.aluminum_mol,
                .iron_mol = record.transfer.iron_mol,
                .calcium_mol = record.transfer.calcium_mol,
                .magnesium_mol = record.transfer.magnesium_mol,
                .sodium_mol = record.transfer.sodium_mol,
                .potassium_mol = record.transfer.potassium_mol,
                .sulfur_mol = record.transfer.sulfur_mol,
                .chloride_mol = record.transfer.chloride_mol,
                .silicon_mol = record.transfer.silicon_mol,
                .sand_megagrams = record.transfer.sand_megagrams,
                .silt_megagrams = record.transfer.silt_megagrams,
                .clay_megagrams = record.transfer.clay_megagrams,
                .rock_additive = record.transfer.rock_additive,
                .cation_exchange_capacity_mol = record.transfer.cation_exchange_capacity_mol,
                .anion_exchange_capacity_mol = record.transfer.anion_exchange_capacity_mol,
            });
            const has_material = !std.meta.eql(material, hourly.IntercellTransfer{});
            const has_heat = record.transfer.heat_megajoules != 0;
            const inactive_face = active < 2 or upper < first or upper >= first + active - 1;
            if (inactive_face) {
                if (record.direction != .none or record.heat_direction != .none or
                    has_material or has_heat or record.transfer.ion_inventory_mol != 0)
                    return error.InactiveLayerConservationActivity;
                continue;
            }
            // A processed face may legitimately move a zero amount, so a
            // non-none material direction does not by itself imply activity.
            if ((record.direction == .none and has_material) or
                (record.heat_direction == .none) != !has_heat)
                return error.InvalidLayerConservationActivity;
            if (has_material)
                try accumulateRelayeringDirection(&candidate, cell, upper, record.direction, material);
            if (has_heat)
                try accumulateRelayeringDirection(
                    &candidate,
                    cell,
                    upper,
                    record.heat_direction,
                    .{ .heat_megajoules = record.transfer.heat_megajoules },
                );
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Books accepted REDIST tillage paths without reducing opposing transfers
/// to a net layer delta. Frozen material may carry negative referenced
/// enthalpy, so material and heat directions are applied independently.
pub fn accumulateTillageActivity(
    ledger: *Ledger,
    sidecar: *const tillage_activity.Sidecar,
) !void {
    try sidecar.validateLayout(ledger.layout.cell_count, ledger.layout.soil_layer_capacity);
    if (sidecar.attempt_active) return error.LayerConservationActivityAttemptActive;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    const layers = ledger.layout.soil_layer_capacity;
    for (0..ledger.layout.cell_count) |cell| {
        for (0..layers) |donor| for (0..layers) |recipient| {
            const record = try sidecar.soilRecord(cell, donor, recipient);
            try accumulateTillageRecord(
                &candidate,
                .{ .kind = .soil_layer, .cell = cell, .layer = donor },
                .{ .kind = .soil_layer, .cell = cell, .layer = recipient },
                record,
            );
        };
        for (0..layers) |recipient| {
            const record = try sidecar.surfaceRecord(cell, recipient);
            try accumulateTillageRecord(
                &candidate,
                .{ .kind = .surface, .cell = cell },
                .{ .kind = .soil_layer, .cell = cell, .layer = recipient },
                record,
            );
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

fn accumulateTillageRecord(
    ledger: *Ledger,
    material_donor: ScopeAddress,
    material_recipient: ScopeAddress,
    record: tillage_activity.Record,
) !void {
    try record.transfer.validate();
    const heat = record.transfer.heat_megajoules;
    var material_storage = record.transfer;
    material_storage.heat_megajoules = 0;
    const material = try storageToIntercellTransfer(material_storage);
    const has_material = !std.meta.eql(material, hourly.IntercellTransfer{});
    if (!record.active) {
        if (has_material or heat != 0 or record.heat_reversed)
            return error.InvalidLayerConservationActivity;
        return;
    }
    if (material_donor.kind == .soil_layer and material_recipient.kind == .soil_layer and
        material_donor.cell == material_recipient.cell and material_donor.layer == material_recipient.layer)
        return error.InvalidLayerConservationTransfer;
    if (has_material) try ledger.accumulateTransfer(material_donor, material_recipient, material);
    if (heat != 0) try ledger.accumulateTransfer(
        if (record.heat_reversed) material_recipient else material_donor,
        if (record.heat_reversed) material_donor else material_recipient,
        .{ .heat_megajoules = heat },
    );
}

test "tillage activity publishes opposing layer paths and reversed frozen heat atomically" {
    var sidecar = try tillage_activity.Sidecar.init(
        std.testing.allocator,
        1,
        2,
        .{ .relative = 64 * std.math.floatEps(f64) },
    );
    defer sidecar.deinit();
    try sidecar.beginAttempt();
    try sidecar.stageCell(
        0,
        0,
        1,
        0.2,
        0.5,
        &.{ 0.1, 0.2 },
        &.{ 0.1, 0.1 },
        0,
        &.{
            .{ .water_m3 = 10, .heat_megajoules = -10 },
            .{ .water_m3 = 2, .heat_megajoules = -2 },
        },
        .{ .water_m3 = 2, .heat_megajoules = -2 },
        .{ .water_m3 = 2, .heat_megajoules = -2 },
        &.{
            .{ .water_m3 = 9, .heat_megajoules = -9 },
            .{ .water_m3 = 5, .heat_megajoules = -5 },
        },
        .{},
    );
    try sidecar.commitAttempt();
    var ledger = try Ledger.init(std.testing.allocator, try Layout.init(1, 2, 1));
    defer ledger.deinit();
    try accumulateTillageActivity(&ledger, &sidecar);
    const surface = ledger.activity[try ledger.layout.index(.{ .kind = .surface, .cell = 0 })];
    const upper = ledger.activity[try ledger.layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 })];
    const lower = ledger.activity[try ledger.layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 })];
    try std.testing.expectEqual(@as(f64, 2), surface.water_output_m3);
    try std.testing.expectEqual(@as(f64, 2), surface.heat_input_megajoules);
    try std.testing.expectEqual(@as(f64, 2.5), upper.water_output_m3);
    try std.testing.expectEqual(@as(f64, 1.5), upper.water_input_m3);
    try std.testing.expectEqual(@as(f64, 3.5), lower.water_input_m3);
    try std.testing.expectEqual(@as(f64, 0.5), lower.water_output_m3);
    try std.testing.expectEqual(@as(f64, 2.5), upper.heat_input_megajoules);
    try std.testing.expectEqual(@as(f64, 1.5), upper.heat_output_megajoules);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    sidecar.accepted_surface[0] = .{ .active = false, .transfer = .{ .water_m3 = 1 } };
    try std.testing.expectError(error.InvalidLayerConservationActivity, accumulateTillageActivity(&ledger, &sidecar));
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

fn accumulateRelayeringDirection(
    ledger: *Ledger,
    cell: usize,
    upper: usize,
    direction: soil_relayering_activity.Direction,
    transfer: hourly.IntercellTransfer,
) !void {
    const upper_address: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = upper };
    const lower_address: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = upper + 1 };
    switch (direction) {
        .upper_to_lower => try ledger.accumulateTransfer(upper_address, lower_address, transfer),
        .lower_to_upper => try ledger.accumulateTransfer(lower_address, upper_address, transfer),
        .none => return error.InvalidLayerConservationActivity,
    }
}

test "soil relayering publishes material and negative enthalpy in independent directions" {
    var sidecar = try soil_relayering_activity.Sidecar.init(
        std.testing.allocator,
        1,
        2,
        .{ .relative = 32 * std.math.floatEps(f64) },
    );
    defer sidecar.deinit();
    try sidecar.beginAttempt();
    try sidecar.stageBoundary(
        0,
        1,
        0,
        .{ .water_m3 = 10, .heat_megajoules = -10, .organic_carbon_g = 3 },
        .{ .water_m3 = 2, .heat_megajoules = -2, .organic_carbon_g = 4 },
        .{ .water_m3 = 6, .heat_megajoules = -6, .organic_carbon_g = 2 },
        .{ .water_m3 = 6, .heat_megajoules = -6, .organic_carbon_g = 5 },
    );
    try sidecar.commitAttempt();

    var ledger = try Ledger.init(std.testing.allocator, try Layout.init(1, 2, 1));
    defer ledger.deinit();
    try accumulateSoilRelayeringActivity(&ledger, &sidecar, &.{0}, &.{2});
    const upper = ledger.activity[try ledger.layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 })];
    const lower = ledger.activity[try ledger.layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 })];
    try std.testing.expectEqual(@as(f64, 4), upper.water_input_m3);
    try std.testing.expectEqual(@as(f64, 1), upper.carbon_input_g);
    try std.testing.expectEqual(@as(f64, 4), upper.heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 4), lower.water_output_m3);
    try std.testing.expectEqual(@as(f64, 1), lower.carbon_output_g);
    try std.testing.expectEqual(@as(f64, 4), lower.heat_input_megajoules);
}

test "soil relayering adapter rejects inactive activity atomically" {
    var sidecar = try soil_relayering_activity.Sidecar.init(
        std.testing.allocator,
        1,
        3,
        .{ .relative = 32 * std.math.floatEps(f64) },
    );
    defer sidecar.deinit();
    sidecar.accepted[1] = .{
        .direction = .upper_to_lower,
        .transfer = .{ .water_m3 = 1 },
    };
    var ledger = try Ledger.init(std.testing.allocator, try Layout.init(1, 3, 1));
    defer ledger.deinit();
    ledger.activity[0].water_input_m3 = 7;
    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulateSoilRelayeringActivity(&ledger, &sidecar, &.{0}, &.{2}),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "soil relayering adapter honors nonzero first active layer" {
    var sidecar = try soil_relayering_activity.Sidecar.init(
        std.testing.allocator,
        1,
        3,
        .{ .relative = 32 * std.math.floatEps(f64) },
    );
    defer sidecar.deinit();
    try sidecar.beginAttempt();
    try sidecar.stageBoundary(
        0,
        1,
        2,
        .{ .water_m3 = 3 },
        .{ .water_m3 = 1 },
        .{ .water_m3 = 2 },
        .{ .water_m3 = 2 },
    );
    try sidecar.commitAttempt();

    var ledger = try Ledger.init(std.testing.allocator, try Layout.init(1, 3, 1));
    defer ledger.deinit();
    try accumulateSoilRelayeringActivity(&ledger, &sidecar, &.{1}, &.{2});

    const inactive = ledger.activity[try ledger.layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 })];
    const upper = ledger.activity[try ledger.layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 })];
    const lower = ledger.activity[try ledger.layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 2 })];
    try std.testing.expectEqualDeep(hourly.BoundaryActivity{}, inactive);
    try std.testing.expectEqual(@as(f64, 1), upper.water_output_m3);
    try std.testing.expectEqual(@as(f64, 1), lower.water_input_m3);
}

/// Exact NITRO.F 4168--4275 adjacent-soil FOMCX transfer. Each producer slot
/// is the face whose upper owner has the same flat layer index. Keeping the
/// signed producer direction until this boundary prevents opposite-direction
/// mixing on different faces from cancelling before local acceptance.
pub fn accumulateSoilMicrobialMixingActivity(
    ledger: *Ledger,
    active_soil_layer_count: []const usize,
    owned_cells: []const usize,
    accepted_face_transfer: []const soil_microbial_mixing.SignedElementTransfer,
) !void {
    if (active_soil_layer_count.len != ledger.layout.cell_count or
        accepted_face_transfer.len != try ledger.layout.soilCount())
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (owned_cells) |cell| {
        if (cell >= ledger.layout.cell_count) return error.LayerConservationScopeOutOfBounds;
        const active = active_soil_layer_count[cell];
        if (active > ledger.layout.soil_layer_capacity) return error.InvalidActiveSoilLayerCount;
        for (0..(active -| 1)) |layer| {
            const signed = accepted_face_transfer[cell * ledger.layout.soil_layer_capacity + layer];
            const transfer = try signedElementTransfer(signed.carbon_g_c, signed.nitrogen_g_n, signed.phosphorus_g_p);
            if (std.meta.eql(transfer, hourly.IntercellTransfer{})) continue;
            const upper: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = layer };
            const lower: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = layer + 1 };
            if (signedDirection(signed.carbon_g_c, signed.nitrogen_g_n, signed.phosphorus_g_p) > 0)
                try candidate.accumulateTransfer(upper, lower, transfer)
            else
                try candidate.accumulateTransfer(lower, upper, transfer);
        }
        for ((active -| 1)..ledger.layout.soil_layer_capacity) |layer| {
            const value = accepted_face_transfer[cell * ledger.layout.soil_layer_capacity + layer];
            if (!std.meta.eql(value, soil_microbial_mixing.SignedElementTransfer{}))
                return error.InactiveLayerConservationActivity;
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Exact L=0/LL=NU microbial mixing. Positive producer values move surface
/// microbial CNP into topsoil; negative values retain the reverse source
/// direction. A zero-soil cell must publish no activity.
pub fn accumulateSurfaceTopsoilMicrobialMixingActivity(
    ledger: *Ledger,
    active_soil_layer_count: []const usize,
    owned_cells: []const usize,
    accepted_surface_to_topsoil: []const surface_microbial_mixing.SignedElementTransfer,
) !void {
    if (active_soil_layer_count.len != ledger.layout.cell_count or
        accepted_surface_to_topsoil.len != ledger.layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (owned_cells) |cell| {
        if (cell >= ledger.layout.cell_count) return error.LayerConservationScopeOutOfBounds;
        const active = active_soil_layer_count[cell];
        if (active > ledger.layout.soil_layer_capacity) return error.InvalidActiveSoilLayerCount;
        const signed = accepted_surface_to_topsoil[cell];
        const transfer = try signedElementTransfer(signed.carbon_g_c, signed.nitrogen_g_n, signed.phosphorus_g_p);
        if (active == 0) {
            if (!std.meta.eql(transfer, hourly.IntercellTransfer{}))
                return error.InactiveLayerConservationActivity;
            continue;
        }
        if (std.meta.eql(transfer, hourly.IntercellTransfer{})) continue;
        const surface: ScopeAddress = .{ .kind = .surface, .cell = cell };
        const topsoil: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = 0 };
        if (signedDirection(signed.carbon_g_c, signed.nitrogen_g_n, signed.phosphorus_g_p) > 0)
            try candidate.accumulateTransfer(surface, topsoil, transfer)
        else
            try candidate.accumulateTransfer(topsoil, surface, transfer);
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Exact accepted WATSUB/TRNSFR litter--topsoil transfer. Each direction is
/// retained separately because simultaneous diffusion/dispersion of distinct
/// species can move the same conserved element in opposing directions. This
/// is local activity only: both scopes belong to one horizontal cell, so the
/// horizontal-cell and landscape boundary ledgers must remain unchanged.
pub fn accumulateLitterSoilInterfaceActivity(
    ledger: *Ledger,
    active_soil_layer_count: []const usize,
    surface_to_topsoil: []const hourly.IntercellTransfer,
    topsoil_to_surface: []const hourly.IntercellTransfer,
) !void {
    if (active_soil_layer_count.len != ledger.layout.cell_count or
        surface_to_topsoil.len != ledger.layout.cell_count or
        topsoil_to_surface.len != ledger.layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{
        .allocator = ledger.allocator,
        .layout = ledger.layout,
        .activity = candidate_values,
    };
    for (active_soil_layer_count, 0..) |active, cell| {
        if (active > ledger.layout.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        const downward = surface_to_topsoil[cell];
        const upward = topsoil_to_surface[cell];
        try validateTransfer(downward);
        try validateTransfer(upward);
        if (active == 0) {
            if (!std.meta.eql(downward, hourly.IntercellTransfer{}) or
                !std.meta.eql(upward, hourly.IntercellTransfer{}))
                return error.InactiveLayerConservationActivity;
            continue;
        }
        const surface: ScopeAddress = .{ .kind = .surface, .cell = cell };
        const topsoil: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = 0 };
        if (!std.meta.eql(downward, hourly.IntercellTransfer{}))
            try candidate.accumulateTransfer(surface, topsoil, downward);
        if (!std.meta.eql(upward, hourly.IntercellTransfer{}))
            try candidate.accumulateTransfer(topsoil, surface, upward);
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Gross L=0/LL=NU transfers accepted by the two surface metabolism owners.
/// Heterotrophic and K=5 autotrophic mineral uptake and organic return remain
/// separate ledger transactions so simultaneous opposite CNP directions
/// cannot cancel. The producers are exact NITRO state-update operands, not
/// before/after residuals.
pub fn accumulateSurfaceBiogeochemicalActivity(
    ledger: *Ledger,
    active_soil_layer_count: []const usize,
    owned_cells: []const usize,
    decomposition: *const surface_organic_decomposition.State,
    turnover: *const surface_microbial_turnover.State,
    heterotrophic_topsoil_exchange: *const surface_topsoil_exchange.State,
    autotrophic: *const surface_autotrophic.State,
    accepted_autotrophic_topsoil_organic: []const organic_state.ElementPool,
) !void {
    if (active_soil_layer_count.len != ledger.layout.cell_count or
        decomposition.cell_count != ledger.layout.cell_count or
        turnover.cell_count != ledger.layout.cell_count or
        heterotrophic_topsoil_exchange.cell_count != ledger.layout.cell_count or
        autotrophic.cell_count != ledger.layout.cell_count or
        accepted_autotrophic_topsoil_organic.len != ledger.layout.cell_count * surface_autotrophic.active_population_count)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (owned_cells) |cell| {
        if (cell >= ledger.layout.cell_count) return error.LayerConservationScopeOutOfBounds;
        const active = active_soil_layer_count[cell];
        if (active > ledger.layout.soil_layer_capacity) return error.InvalidActiveSoilLayerCount;
        const surface: ScopeAddress = .{ .kind = .surface, .cell = cell };
        const topsoil: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = 0 };

        var heterotrophic_mineral: hourly.IntercellTransfer = .{};
        const first_unit = cell * surface_microbial_respiration.unit_count_per_cell;
        for (first_unit..first_unit + surface_microbial_respiration.unit_count_per_cell) |unit| {
            heterotrophic_mineral.nitrogen_g += heterotrophic_topsoil_exchange.ammonium_exchange_g_n[unit] +
                heterotrophic_topsoil_exchange.nitrate_exchange_g_n[unit];
            heterotrophic_mineral.phosphorus_g += heterotrophic_topsoil_exchange.h2po4_exchange_g_p[unit] +
                heterotrophic_topsoil_exchange.hpo4_exchange_g_p[unit];
        }
        try validateTransfer(heterotrophic_mineral);

        var heterotrophic_organic: hourly.IntercellTransfer = .{};
        const first_structural = cell * surface_microbial_respiration.litter_complex_count * organic_state.structural_fraction_count;
        const end_structural = first_structural + surface_microbial_respiration.litter_complex_count * organic_state.structural_fraction_count;
        for (decomposition.particulate_products[first_structural..end_structural]) |pool|
            try addElementPoolTransfer(&heterotrophic_organic, pool.carbon_g_c, pool.nitrogen_g_n, pool.phosphorus_g_p);
        const first_turnover = first_unit * surface_microbial_turnover.structural_component_count;
        const end_turnover = (first_unit + surface_microbial_respiration.unit_count_per_cell) * surface_microbial_turnover.structural_component_count;
        for (first_turnover..end_turnover) |index| {
            const basal = turnover.basal[index].humified;
            const senescence = turnover.senescence[index].humified;
            try addElementPoolTransfer(&heterotrophic_organic, basal.carbon_g_c, basal.nitrogen_g_n, basal.phosphorus_g_p);
            try addElementPoolTransfer(&heterotrophic_organic, senescence.carbon_g_c, senescence.nitrogen_g_n, senescence.phosphorus_g_p);
        }

        var autotrophic_mineral: hourly.IntercellTransfer = .{};
        var autotrophic_organic: hourly.IntercellTransfer = .{};
        const first_auto = cell * surface_autotrophic.active_population_count;
        for (first_auto..first_auto + surface_autotrophic.active_population_count) |unit| {
            autotrophic_mineral.nitrogen_g += autotrophic.topsoil_ammonium_exchange_g_n[unit] +
                autotrophic.topsoil_nitrate_exchange_g_n[unit];
            autotrophic_mineral.phosphorus_g += autotrophic.topsoil_h2po4_exchange_g_p[unit] +
                autotrophic.topsoil_hpo4_exchange_g_p[unit];
            try addElementPoolTransfer(
                &autotrophic_organic,
                accepted_autotrophic_topsoil_organic[unit].carbon_g_c,
                accepted_autotrophic_topsoil_organic[unit].nitrogen_g_n,
                accepted_autotrophic_topsoil_organic[unit].phosphorus_g_p,
            );
        }
        try validateTransfer(autotrophic_mineral);
        if (active == 0) {
            inline for (.{ heterotrophic_mineral, heterotrophic_organic, autotrophic_mineral, autotrophic_organic }) |transfer|
                if (!std.meta.eql(transfer, hourly.IntercellTransfer{})) return error.InactiveLayerConservationActivity;
            continue;
        }
        inline for (.{ heterotrophic_mineral, autotrophic_mineral }) |transfer|
            if (!std.meta.eql(transfer, hourly.IntercellTransfer{}))
                try candidate.accumulateTransfer(topsoil, surface, transfer);
        inline for (.{ heterotrophic_organic, autotrophic_organic }) |transfer|
            if (!std.meta.eql(transfer, hourly.IntercellTransfer{}))
                try candidate.accumulateTransfer(surface, topsoil, transfer);
    }
    @memcpy(ledger.activity, candidate.activity);
}

fn addElementPoolTransfer(total: *hourly.IntercellTransfer, carbon: f64, nitrogen: f64, phosphorus: f64) !void {
    inline for (.{ carbon, nitrogen, phosphorus }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidLayerConservationTransfer;
    total.carbon_g = try addNonnegativeTransfer(total.carbon_g, carbon);
    total.nitrogen_g = try addNonnegativeTransfer(total.nitrogen_g, nitrogen);
    total.phosphorus_g = try addNonnegativeTransfer(total.phosphorus_g, phosphorus);
}

fn addNonnegativeTransfer(left: f64, right: f64) !f64 {
    const result = left + right;
    if (!std.math.isFinite(result) or result < 0) return error.InvalidLayerConservationTransfer;
    return result;
}

/// Per-layer O2 consumption and H2 production/consumption from the same
/// accepted NITRO operands that update the inventoried soil gas pools.
pub fn accumulateSoilBiogeochemicalReactions(
    ledger: *Ledger,
    active_soil_layer_count: []const usize,
    owned_cells: []const usize,
    oxygen: *const soil_oxygen_allocation.State,
    products: *const soil_respiration_products.State,
    methane: ?*const soil_methane.State,
) !void {
    const layer_count = try ledger.layout.soilCount();
    if (active_soil_layer_count.len != ledger.layout.cell_count or
        oxygen.cell_count != ledger.layout.cell_count or
        oxygen.layer_count != ledger.layout.soil_layer_capacity or
        products.layer_count != layer_count or
        products.process_unit_count_per_layer != oxygen.population_count or
        (methane != null and methane.?.layer_count != layer_count))
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (owned_cells) |cell| {
        if (cell >= ledger.layout.cell_count) return error.LayerConservationScopeOutOfBounds;
        const active = active_soil_layer_count[cell];
        if (active > ledger.layout.soil_layer_capacity) return error.InvalidActiveSoilLayerCount;
        for (0..ledger.layout.soil_layer_capacity) |layer| {
            const flat = cell * ledger.layout.soil_layer_capacity + layer;
            const first = flat * oxygen.population_count;
            var oxygen_consumption: f64 = 0;
            var hydrogen_production: f64 = 0;
            for (first..first + oxygen.population_count) |unit| {
                oxygen_consumption = try addNonnegativeTransfer(oxygen_consumption, oxygen.oxygen_uptake_g_o[unit]);
                hydrogen_production = try addNonnegativeTransfer(hydrogen_production, products.hydrogen_g_h[unit]);
            }
            const hydrogen_consumption = if (methane) |state| state.hydrogen_consumption_g_h[flat] else 0;
            if (!std.math.isFinite(hydrogen_consumption) or hydrogen_consumption < 0)
                return error.InvalidLayerConservationActivity;
            if (layer >= active) {
                if (oxygen_consumption != 0 or hydrogen_production != 0 or hydrogen_consumption != 0)
                    return error.InactiveLayerConservationActivity;
                continue;
            }
            try candidate.accumulate(.{ .kind = .soil_layer, .cell = cell, .layer = layer }, .{
                .oxygen_internal_consumption_g = oxygen_consumption,
                .hydrogen_internal_production_g = hydrogen_production,
                .hydrogen_internal_consumption_g = hydrogen_consumption,
            });
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Surface counterpart of the soil reaction activity. Source population N=5
/// (active index 3) is the sole K=5 hydrogenotrophic H2 sink; all 25 accepted
/// heterotrophic/autotrophic allocation slots contribute their O2 uptake.
pub fn accumulateSurfaceBiogeochemicalReactions(
    ledger: *Ledger,
    owned_cells: []const usize,
    oxygen: *const surface_oxygen.State,
    autotrophic: *const surface_autotrophic.State,
) !void {
    if (oxygen.cell_count != ledger.layout.cell_count or
        autotrophic.cell_count != ledger.layout.cell_count or
        oxygen.allocation.population_count != surface_oxygen.unit_count_per_cell)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    const hydrogenotroph: usize = 3;
    comptime std.debug.assert(surface_autotrophic.source_population_by_active[hydrogenotroph] == 4);
    for (owned_cells) |cell| {
        if (cell >= ledger.layout.cell_count) return error.LayerConservationScopeOutOfBounds;
        var oxygen_consumption: f64 = 0;
        const first = cell * surface_oxygen.unit_count_per_cell;
        for (oxygen.allocation.oxygen_uptake_g_o[first .. first + surface_oxygen.unit_count_per_cell]) |value|
            oxygen_consumption = try addNonnegativeTransfer(oxygen_consumption, value);
        const hydrogen_production = oxygen.respiration_hydrogen_g_h_per_step[cell];
        const hydrogen_consumption = autotrophic.actual_primary_reaction[cell * surface_autotrophic.active_population_count + hydrogenotroph];
        inline for (.{ hydrogen_production, hydrogen_consumption }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidLayerConservationActivity;
        try candidate.accumulate(.{ .kind = .surface, .cell = cell }, .{
            .oxygen_internal_consumption_g = oxygen_consumption,
            .hydrogen_internal_production_g = hydrogen_production,
            .hydrogen_internal_consumption_g = hydrogen_consumption,
        });
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Generic signed internal heat in the surface scope. Positive values are
/// production and negative values consumption.
pub fn accumulateSurfaceSignedInternalHeat(
    ledger: *Ledger,
    signed_heat_megajoules_by_cell: []const f64,
) !void {
    if (signed_heat_megajoules_by_cell.len != ledger.layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (signed_heat_megajoules_by_cell, 0..) |heat, cell| {
        if (!std.math.isFinite(heat)) return error.InvalidLayerConservationActivity;
        try candidate.accumulate(.{ .kind = .surface, .cell = cell }, if (heat >= 0)
            .{ .heat_internal_production_megajoules = heat }
        else
            .{ .heat_internal_consumption_megajoules = -heat });
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Generic signed internal heat owned by individual active soil layers.
/// Positive values are production and negative values consumption. Capacity
/// slots beyond each cell's active layer count are not control volumes and
/// must remain exactly zero.
pub fn accumulateSoilLayerSignedInternalHeat(
    ledger: *Ledger,
    active_soil_layer_count: []const usize,
    signed_heat_megajoules_by_layer: []const f64,
) !void {
    if (active_soil_layer_count.len != ledger.layout.cell_count or
        signed_heat_megajoules_by_layer.len != try ledger.layout.soilCount())
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (active_soil_layer_count, 0..) |active, cell| {
        if (active > ledger.layout.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        for (0..ledger.layout.soil_layer_capacity) |layer| {
            const heat = signed_heat_megajoules_by_layer[
                cell * ledger.layout.soil_layer_capacity + layer
            ];
            if (!std.math.isFinite(heat))
                return error.InvalidLayerConservationActivity;
            if (layer >= active) {
                if (heat != 0) return error.InactiveLayerConservationActivity;
                continue;
            }
            try candidate.accumulate(
                .{ .kind = .soil_layer, .cell = cell, .layer = layer },
                if (heat >= 0)
                    .{ .heat_internal_production_megajoules = heat }
                else
                    .{ .heat_internal_consumption_megajoules = -heat },
            );
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Pair the accepted conductive surface-energy flux with the exact topsoil
/// recipient. Positive values enter topsoil; negative values leave topsoil.
/// This is internal to one horizontal cell and must remain direction-separated
/// until both local scopes have been booked.
pub fn accumulateSurfaceTopsoilHeatTransfer(
    ledger: *Ledger,
    active_soil_layer_count: []const usize,
    signed_heat_into_topsoil_megajoules_by_layer: []const f64,
) !void {
    const soil_count = try ledger.layout.soilCount();
    if (active_soil_layer_count.len != ledger.layout.cell_count or
        signed_heat_into_topsoil_megajoules_by_layer.len != soil_count)
        return error.LayerConservationActivityDimensionMismatch;

    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (active_soil_layer_count, 0..) |active_layers, cell| {
        if (active_layers > ledger.layout.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        const base = cell * ledger.layout.soil_layer_capacity;
        for (signed_heat_into_topsoil_megajoules_by_layer[base .. base + ledger.layout.soil_layer_capacity], 0..) |heat, local_layer| {
            if (!std.math.isFinite(heat)) return error.InvalidLayerConservationActivity;
            if (local_layer != 0 and heat != 0)
                return error.InvalidLayerConservationActivity;
        }
        const signed_heat = signed_heat_into_topsoil_megajoules_by_layer[base];
        if (active_layers == 0) {
            if (signed_heat != 0) return error.InactiveLayerConservationActivity;
            continue;
        }
        if (signed_heat == 0) continue;
        const surface: ScopeAddress = .{ .kind = .surface, .cell = cell };
        const topsoil: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = 0 };
        if (signed_heat > 0)
            try candidate.accumulateTransfer(surface, topsoil, .{ .heat_megajoules = signed_heat })
        else
            try candidate.accumulateTransfer(topsoil, surface, .{ .heat_megajoules = -signed_heat });
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// REDIST HFLXO/HEATIN rebase caused by a surface organic-carbon capacity
/// change at fixed temperature.
pub fn accumulateSurfaceOrganicHeatRebase(
    ledger: *Ledger,
    signed_heat_megajoules_by_cell: []const f64,
) !void {
    return accumulateSurfaceSignedInternalHeat(
        ledger,
        signed_heat_megajoules_by_cell,
    );
}

/// Surface-scope endpoint-reference heat paired with the WATSUB surface
/// enthalpy solve. This mirrors the cell and landscape ledgers exactly.
pub fn accumulateSurfaceEndpointReferenceHeat(
    ledger: *Ledger,
    ice_water_equivalent_change_m3: []const f64,
    internal_vapor_water_change_m3: []const f64,
    liquid_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_per_water_equivalent_m3_k: f64,
    pure_water_melting_temperature_k: f64,
    latent_heat_of_vaporization_megajoules_per_m3: f64,
) !void {
    if (ice_water_equivalent_change_m3.len != ledger.layout.cell_count or
        internal_vapor_water_change_m3.len != ledger.layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    const signed_heat = try ledger.allocator.alloc(f64, ledger.layout.cell_count);
    defer ledger.allocator.free(signed_heat);
    for (signed_heat, 0..) |*value, cell| {
        value.* = hourly.surfaceEndpointReferenceHeatMegajoules(
            ice_water_equivalent_change_m3[cell],
            internal_vapor_water_change_m3[cell],
            liquid_heat_capacity_megajoules_per_m3_k,
            ice_heat_capacity_per_water_equivalent_m3_k,
            pure_water_melting_temperature_k,
            latent_heat_of_vaporization_megajoules_per_m3,
        ) catch return error.InvalidLayerConservationActivity;
    }
    try accumulateSurfaceSignedInternalHeat(ledger, signed_heat);
}

/// UPTAKE HCBFCY/HCBFDY are previous-hour combustion heat impulses applied
/// to the living and standing-dead canopy-air states before their surface
/// energy solves.  Preserve the per-plant producers until this boundary so
/// simultaneous populations cannot hide a non-finite/negative source.
pub fn accumulateCanopyCombustionHeat(
    ledger: *Ledger,
    plant_populations_per_cell: usize,
    living_heat_megajoules_by_plant: []const f64,
    standing_dead_heat_megajoules_by_plant: []const f64,
) !void {
    if (plant_populations_per_cell == 0)
        return error.LayerConservationActivityDimensionMismatch;
    const plant_count = try std.math.mul(usize, ledger.layout.cell_count, plant_populations_per_cell);
    if (living_heat_megajoules_by_plant.len != plant_count or
        standing_dead_heat_megajoules_by_plant.len != plant_count)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (0..ledger.layout.cell_count) |cell| {
        var total: f64 = 0;
        const first = cell * plant_populations_per_cell;
        for (first..first + plant_populations_per_cell) |plant| {
            total = try addNonnegativeTransfer(total, living_heat_megajoules_by_plant[plant]);
            total = try addNonnegativeTransfer(total, standing_dead_heat_megajoules_by_plant[plant]);
        }
        try candidate.accumulate(.{ .kind = .canopy, .cell = cell }, .{
            .heat_internal_production_megajoules = total,
        });
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// REDIST HCBFX(0) is the delayed litter/surface combustion heat consumed by
/// the accepted surface-temperature transaction.
pub fn accumulateSurfaceCombustionHeat(
    ledger: *Ledger,
    heat_megajoules_by_cell: []const f64,
) !void {
    if (heat_megajoules_by_cell.len != ledger.layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (heat_megajoules_by_cell, 0..) |heat, cell| {
        _ = try addNonnegativeTransfer(0, heat);
        try candidate.accumulate(.{ .kind = .surface, .cell = cell }, .{
            .heat_internal_production_megajoules = heat,
        });
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// REDIST HCBFX(L>0) is consumed by the owning active soil layer.  Capacity
/// slots are not scientific control volumes and must carry exactly zero.
pub fn accumulateSoilCombustionHeat(
    ledger: *Ledger,
    active_soil_layer_count: []const usize,
    heat_megajoules_by_layer: []const f64,
) !void {
    if (active_soil_layer_count.len != ledger.layout.cell_count or
        heat_megajoules_by_layer.len != try ledger.layout.soilCount())
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (active_soil_layer_count, 0..) |active, cell| {
        if (active > ledger.layout.soil_layer_capacity) return error.InvalidActiveSoilLayerCount;
        for (0..ledger.layout.soil_layer_capacity) |layer| {
            const heat = heat_megajoules_by_layer[cell * ledger.layout.soil_layer_capacity + layer];
            _ = try addNonnegativeTransfer(0, heat);
            if (layer >= active) {
                if (heat != 0) return error.InactiveLayerConservationActivity;
                continue;
            }
            try candidate.accumulate(.{ .kind = .soil_layer, .cell = cell, .layer = layer }, .{
                .heat_internal_production_megajoules = heat,
            });
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// GROSUB true harvest products contain aboveground/canopy CNP only. Root
/// harvest is retained as layer-local litter by the producer and is therefore
/// excluded from this external canopy boundary.
pub fn accumulateCanopyHarvest(
    ledger: *Ledger,
    cell: usize,
    carbon_g_c: f64,
    nitrogen_g_n: f64,
    phosphorus_g_p: f64,
) !void {
    if (cell >= ledger.layout.cell_count) return error.LayerConservationScopeOutOfBounds;
    inline for (.{ carbon_g_c, nitrogen_g_n, phosphorus_g_p }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLayerConservationActivity;
    try ledger.accumulate(.{ .kind = .canopy, .cell = cell }, .{
        .carbon_output_g = carbon_g_c,
        .nitrogen_output_g = nitrogen_g_n,
        .phosphorus_output_g = phosphorus_g_p,
    });
}

/// Dynamic plant-salt harvest is likewise shoot-only. Preserve the producer's
/// Al, Fe, Ca, Mg, Na, K, SO4, Cl order and publish it at the canopy scope.
pub fn accumulateCanopyHarvestSalt(
    ledger: *Ledger,
    cell: usize,
    harvested_salt_mol: []const f64,
) !void {
    if (cell >= ledger.layout.cell_count) return error.LayerConservationScopeOutOfBounds;
    try ledger.accumulate(
        .{ .kind = .canopy, .cell = cell },
        try hourly.plantSaltElementActivity(harvested_salt_mol, .output),
    );
}

/// EXTRACT grazing manure is an internal canopy -> litter/surface CNP
/// transfer. Organic fractions and inorganic N/P are combined only after the
/// exact producer validates; donor and recipient are then published together.
pub fn accumulateCanopySurfaceManure(
    ledger: *Ledger,
    plant_populations_per_cell: usize,
    products_by_plant: []const grazing_manure.Products,
) !void {
    if (plant_populations_per_cell == 0 or
        products_by_plant.len != try std.math.mul(usize, ledger.layout.cell_count, plant_populations_per_cell))
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (products_by_plant, 0..) |products, plant| {
        var carbon: f64 = 0;
        var nitrogen = products.inorganic_nitrogen_g_n;
        var phosphorus = products.inorganic_phosphorus_g_p;
        inline for (.{ nitrogen, phosphorus }) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidLayerConservationTransfer;
        for (products.organic_by_biochemical_fraction) |fraction| {
            inline for (.{ fraction.carbon_g, fraction.nitrogen_g, fraction.phosphorus_g }) |value|
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidLayerConservationTransfer;
            carbon = try addNonnegativeTransfer(carbon, fraction.carbon_g);
            nitrogen = try addNonnegativeTransfer(nitrogen, fraction.nitrogen_g);
            phosphorus = try addNonnegativeTransfer(phosphorus, fraction.phosphorus_g);
        }
        const transfer = hourly.IntercellTransfer{
            .carbon_g = carbon,
            .nitrogen_g = nitrogen,
            .phosphorus_g = phosphorus,
        };
        if (std.meta.eql(transfer, hourly.IntercellTransfer{})) continue;
        const cell = plant / plant_populations_per_cell;
        try candidate.accumulateTransfer(
            .{ .kind = .canopy, .cell = cell },
            .{ .kind = .surface, .cell = cell },
            transfer,
        );
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// NITRO/REDIST fire finalization leaves CO2/CH4, mineral N/P, charcoal and
/// salts in the same local storage scope. The only local activity is the O2
/// reaction sink plus gaseous N/P that immediately leaves the modeled scope.
pub fn accumulateSoilSurfaceFireActivity(
    ledger: *Ledger,
    active_soil_layer_count: []const usize,
    surface: *const organic_fire.State,
    soil: *const organic_fire.State,
) !void {
    const soil_count = try ledger.layout.soilCount();
    if (active_soil_layer_count.len != ledger.layout.cell_count or
        surface.layer_count != ledger.layout.cell_count or
        soil.layer_count != soil_count)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (active_soil_layer_count, 0..) |active, cell| {
        if (active > ledger.layout.soil_layer_capacity) return error.InvalidActiveSoilLayerCount;
        const surface_o = surface.oxygen_consumption_g_o[cell];
        const surface_n = surface.gaseous_nitrogen_emission_g_n[cell];
        const surface_p = surface.gaseous_phosphorus_emission_g_p[cell];
        inline for (.{ surface_o, surface_n, surface_p }) |value|
            _ = try addNonnegativeTransfer(0, value);
        try candidate.accumulate(.{ .kind = .surface, .cell = cell }, .{
            .oxygen_internal_consumption_g = surface_o,
            .nitrogen_output_g = surface_n,
            .phosphorus_output_g = surface_p,
        });
        for (0..ledger.layout.soil_layer_capacity) |layer| {
            const flat = cell * ledger.layout.soil_layer_capacity + layer;
            const oxygen = soil.oxygen_consumption_g_o[flat];
            const nitrogen = soil.gaseous_nitrogen_emission_g_n[flat];
            const phosphorus = soil.gaseous_phosphorus_emission_g_p[flat];
            inline for (.{ oxygen, nitrogen, phosphorus }) |value|
                _ = try addNonnegativeTransfer(0, value);
            if (layer >= active) {
                if (oxygen != 0 or nitrogen != 0 or phosphorus != 0)
                    return error.InactiveLayerConservationActivity;
                continue;
            }
            try candidate.accumulate(.{ .kind = .soil_layer, .cell = cell, .layer = layer }, .{
                .oxygen_internal_consumption_g = oxygen,
                .nitrogen_output_g = nitrogen,
                .phosphorus_output_g = phosphorus,
            });
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// EXTRACT shoot combustion returns retained mineral N/P and dynamic salts
/// from canopy storage to the surface pending/dissolved carrier. Gaseous CNP
/// and O2 are owned separately by plantAtmosphere; this is only the paired
/// internal return subset recorded by the shoot-fire producer.
pub fn accumulateCanopySurfaceFireReturns(
    ledger: *Ledger,
    surface: *const organic_fire.State,
    nitrogen_molar_mass_g_per_mol: f64,
    phosphorus_molar_mass_g_per_mol: f64,
) !void {
    if (surface.layer_count != ledger.layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    inline for (.{ nitrogen_molar_mass_g_per_mol, phosphorus_molar_mass_g_per_mol }) |value|
        if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidLayerConservationTransfer;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (0..ledger.layout.cell_count) |cell| {
        const nitrogen = surface.canopy_fire_surface_ammonium_mol_n[cell] * nitrogen_molar_mass_g_per_mol;
        const phosphorus = surface.canopy_fire_surface_phosphate_mol_p[cell] * phosphorus_molar_mass_g_per_mol;
        var transfer: hourly.IntercellTransfer = .{
            .nitrogen_g = nitrogen,
            .phosphorus_g = phosphorus,
        };
        const first = cell * organic_fire.salt_species_count;
        const salts = surface.canopy_fire_surface_salt_mol[first..][0..organic_fire.salt_species_count];
        for (salts) |value| _ = try addNonnegativeTransfer(0, value);
        transfer.aluminum_mol = salts[0];
        transfer.iron_mol = salts[1];
        transfer.calcium_mol = salts[2];
        transfer.magnesium_mol = salts[3];
        transfer.sodium_mol = salts[4];
        transfer.potassium_mol = salts[5];
        transfer.sulfur_mol = salts[6];
        transfer.chloride_mol = salts[7];
        try validateTransfer(transfer);
        if (std.meta.eql(transfer, hourly.IntercellTransfer{})) continue;
        try candidate.accumulateTransfer(
            .{ .kind = .canopy, .cell = cell },
            .{ .kind = .surface, .cell = cell },
            transfer,
        );
    }
    @memcpy(ledger.activity, candidate.activity);
}

test "fire combustion heat reaches exact canopy surface and soil owners atomically" {
    var ledger = try Ledger.init(std.testing.allocator, try Layout.init(2, 2, 1));
    defer ledger.deinit();
    try accumulateCanopyCombustionHeat(&ledger, 2, &.{ 1, 2, 3, 4 }, &.{ 0.5, 0.25, 0.125, 0.0625 });
    try accumulateSurfaceCombustionHeat(&ledger, &.{ 8, 9 });
    try accumulateSoilCombustionHeat(&ledger, &.{ 1, 2 }, &.{ 10, 0, 20, 30 });
    const canopy0 = ledger.activity[try ledger.layout.index(.{ .kind = .canopy, .cell = 0 })];
    const canopy1 = ledger.activity[try ledger.layout.index(.{ .kind = .canopy, .cell = 1 })];
    const surface0 = ledger.activity[try ledger.layout.index(.{ .kind = .surface, .cell = 0 })];
    const soil0 = ledger.activity[try ledger.layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 })];
    const soil10 = ledger.activity[try ledger.layout.index(.{ .kind = .soil_layer, .cell = 1, .layer = 0 })];
    const soil11 = ledger.activity[try ledger.layout.index(.{ .kind = .soil_layer, .cell = 1, .layer = 1 })];
    try std.testing.expectEqual(@as(f64, 3.75), canopy0.heat_internal_production_megajoules);
    try std.testing.expectEqual(@as(f64, 7.1875), canopy1.heat_internal_production_megajoules);
    try std.testing.expectEqual(@as(f64, 8), surface0.heat_internal_production_megajoules);
    try std.testing.expectEqual(@as(f64, 10), soil0.heat_internal_production_megajoules);
    try std.testing.expectEqual(@as(f64, 20), soil10.heat_internal_production_megajoules);
    try std.testing.expectEqual(@as(f64, 30), soil11.heat_internal_production_megajoules);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(
        error.InvalidLayerConservationTransfer,
        accumulateSoilCombustionHeat(&ledger, &.{ 1, 2 }, &.{ -1, 0, 0, 0 }),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "management harvest salt and manure retain exact canopy surface provenance" {
    var ledger = try Ledger.init(std.testing.allocator, try Layout.init(1, 1, 1));
    defer ledger.deinit();
    try accumulateCanopyHarvest(&ledger, 0, 10, 2, 0.5);
    try accumulateCanopyHarvestSalt(&ledger, 0, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    var products = [_]grazing_manure.Products{ .{}, .{} };
    products[0].organic_by_biochemical_fraction[0] = .{ .carbon_g = 3, .nitrogen_g = 0.3, .phosphorus_g = 0.03 };
    products[0].inorganic_nitrogen_g_n = 0.2;
    products[0].inorganic_phosphorus_g_p = 0.02;
    products[1].organic_by_biochemical_fraction[3] = .{ .carbon_g = 4, .nitrogen_g = 0.4, .phosphorus_g = 0.04 };
    try accumulateCanopySurfaceManure(&ledger, 2, &products);
    const canopy = ledger.activity[try ledger.layout.index(.{ .kind = .canopy, .cell = 0 })];
    const surface = ledger.activity[try ledger.layout.index(.{ .kind = .surface, .cell = 0 })];
    try std.testing.expectApproxEqAbs(@as(f64, 17), canopy.carbon_output_g, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2.9), canopy.nitrogen_output_g, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.59), canopy.phosphorus_output_g, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 7), surface.carbon_input_g, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), surface.nitrogen_input_g, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.09), surface.phosphorus_input_g, 1e-14);
    try std.testing.expectEqual(@as(f64, 1), canopy.aluminum_output_mol);
    try std.testing.expectEqual(@as(f64, 7), canopy.sulfur_output_mol);
    try std.testing.expectEqual(@as(f64, 8), canopy.chloride_output_mol);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    products[1].inorganic_nitrogen_g_n = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidLayerConservationTransfer,
        accumulateCanopySurfaceManure(&ledger, 2, &products),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "soil and surface fire publish local oxygen sinks and gaseous nutrient outputs" {
    var ledger = try Ledger.init(std.testing.allocator, try Layout.init(1, 2, 1));
    defer ledger.deinit();
    var surface = try organic_fire.State.init(std.testing.allocator, 1, 6);
    defer surface.deinit();
    var soil = try organic_fire.State.init(std.testing.allocator, 2, 6);
    defer soil.deinit();
    surface.oxygen_consumption_g_o[0] = 1;
    surface.gaseous_nitrogen_emission_g_n[0] = 2;
    surface.gaseous_phosphorus_emission_g_p[0] = 3;
    soil.oxygen_consumption_g_o[0] = 4;
    soil.gaseous_nitrogen_emission_g_n[0] = 5;
    soil.gaseous_phosphorus_emission_g_p[0] = 6;
    try accumulateSoilSurfaceFireActivity(&ledger, &.{1}, &surface, &soil);
    try surface.addCanopyFireSurfaceNutrients(0, 0.5, 0.25);
    try surface.addCanopyFireSurfaceSalts(0, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try accumulateCanopySurfaceFireReturns(&ledger, &surface, 14, 31);
    const surface_activity = ledger.activity[try ledger.layout.index(.{ .kind = .surface, .cell = 0 })];
    const soil_activity = ledger.activity[try ledger.layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 })];
    try std.testing.expectEqual(@as(f64, 1), surface_activity.oxygen_internal_consumption_g);
    try std.testing.expectEqual(@as(f64, 2), surface_activity.nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 3), surface_activity.phosphorus_output_g);
    try std.testing.expectEqual(@as(f64, 4), soil_activity.oxygen_internal_consumption_g);
    try std.testing.expectEqual(@as(f64, 5), soil_activity.nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 6), soil_activity.phosphorus_output_g);
    const canopy_activity = ledger.activity[try ledger.layout.index(.{ .kind = .canopy, .cell = 0 })];
    try std.testing.expectEqual(@as(f64, 7), canopy_activity.nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 7.75), canopy_activity.phosphorus_output_g);
    try std.testing.expectEqual(@as(f64, 1), canopy_activity.aluminum_output_mol);
    try std.testing.expectEqual(@as(f64, 8), canopy_activity.chloride_output_mol);
    try std.testing.expectEqual(@as(f64, 7), surface_activity.nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 7.75), surface_activity.phosphorus_input_g);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    soil.gaseous_nitrogen_emission_g_n[1] = 1;
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulateSoilSurfaceFireActivity(&ledger, &.{1}, &surface, &soil),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

fn signedDirection(carbon: f64, nitrogen: f64, phosphorus: f64) i2 {
    inline for (.{ carbon, nitrogen, phosphorus }) |value| {
        if (value > 0) return 1;
        if (value < 0) return -1;
    }
    return 0;
}

fn signedElementTransfer(carbon: f64, nitrogen: f64, phosphorus: f64) !hourly.IntercellTransfer {
    inline for (.{ carbon, nitrogen, phosphorus }) |value|
        if (!std.math.isFinite(value)) return error.InvalidLayerConservationTransfer;
    const direction = signedDirection(carbon, nitrogen, phosphorus);
    inline for (.{ carbon, nitrogen, phosphorus }) |value|
        if (value != 0 and (if (value > 0) @as(i2, 1) else -1) != direction)
            return error.InvalidLayerConservationTransfer;
    return .{ .carbon_g = @abs(carbon), .nitrogen_g = @abs(nitrogen), .phosphorus_g = @abs(phosphorus) };
}

/// Books only producer-proven canopy/atmosphere activity from EXTRACT. Gross
/// directions are retained so simultaneous condensation and evaporation
/// cannot cancel. Positive intercepted precipitation contributes both water
/// and its accepted atmospheric enthalpy. Negative retention is deliberately
/// excluded here: its lower recipient (snow, surface litter, or topsoil) must
/// be resolved before it can be published as a paired internal transfer.
/// THFLXC is the signed non-precipitation canopy heat boundary in REDIST's
/// `HEATH + THFLXC` balance. Together with retained-rain enthalpy and the
/// paired drainage output it closes the exact EXTRACT ENGYC change.
pub fn accumulateCanopyAtmosphericActivity(
    ledger: *Ledger,
    sidecar: *const canopy_conservation.State,
    accepted_hour_fraction: f64,
) !void {
    if (sidecar.cell_count != ledger.layout.cell_count or
        sidecar.activity_by_cell.len != sidecar.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    if (!std.math.isFinite(accepted_hour_fraction) or
        accepted_hour_fraction <= 0 or accepted_hour_fraction > 1)
        return error.InvalidLayerConservationActivity;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{
        .allocator = ledger.allocator,
        .layout = ledger.layout,
        .activity = candidate_values,
    };
    for (sidecar.activity_by_cell, 0..) |activity, cell| {
        try activity.validate();
        try candidate.accumulate(.{ .kind = .canopy, .cell = cell }, .{
            .water_input_m3 = activity.atmospheric_water_input_m3 * accepted_hour_fraction,
            .water_output_m3 = activity.atmospheric_water_output_m3 * accepted_hour_fraction,
            .heat_input_megajoules = (activity.retained_precipitation_heat_input_megajoules +
                activity.residual_heat_input_megajoules) * accepted_hour_fraction,
            .heat_output_megajoules = activity.residual_heat_output_megajoules * accepted_hour_fraction,
        });
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Publishes the exact accepted above-ground CSNC/ZSNC/PSNC transfer from the
/// plant/canopy inventory to surface organic matter. Root litter is not a
/// cross-scope boundary: both its root donor and organic recipient are
/// inventoried in the same resolved soil layer. GROSUB 12636--12653 sums
/// natural shoot, standing-dead and management litter only after every one has
/// entered the common plant-resolved litter arrays, mirrored by these inputs.
pub fn accumulatePlantLitterfall(
    ledger: *Ledger,
    species_count: usize,
    aboveground_carbon_g_c_by_plant: []const f64,
    aboveground_nitrogen_g_n_by_plant: []const f64,
    aboveground_phosphorus_g_p_by_plant: []const f64,
) !void {
    if (species_count == 0) return error.LayerConservationActivityDimensionMismatch;
    const plant_count = std.math.mul(usize, ledger.layout.cell_count, species_count) catch
        return error.LayerConservationActivityDimensionMismatch;
    if (aboveground_carbon_g_c_by_plant.len != plant_count or
        aboveground_nitrogen_g_n_by_plant.len != plant_count or
        aboveground_phosphorus_g_p_by_plant.len != plant_count)
        return error.LayerConservationActivityDimensionMismatch;

    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{
        .allocator = ledger.allocator,
        .layout = ledger.layout,
        .activity = candidate_values,
    };
    for (0..ledger.layout.cell_count) |cell| {
        var transfer: hourly.IntercellTransfer = .{};
        const first = cell * species_count;
        for (first..first + species_count) |plant| {
            inline for (.{
                .{ "carbon_g", aboveground_carbon_g_c_by_plant[plant] },
                .{ "nitrogen_g", aboveground_nitrogen_g_n_by_plant[plant] },
                .{ "phosphorus_g", aboveground_phosphorus_g_p_by_plant[plant] },
            }) |field_value| {
                const value = field_value[1];
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidLayerConservationActivity;
                const next = @field(transfer, field_value[0]) + value;
                if (!std.math.isFinite(next)) return error.LayerConservationActivityOverflow;
                @field(transfer, field_value[0]) = next;
            }
        }
        try candidate.accumulateTransfer(
            .{ .kind = .canopy, .cell = cell },
            .{ .kind = .surface, .cell = cell },
            transfer,
        );
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Publishes exact accepted GROSUB root--shoot/storage activity without
/// netting opposing C/N/P/salt gradients. Seasonal storage, branches and all
/// above-ground plant pools belong to the canopy scope; each root pool belongs
/// to its resolved soil-layer scope. The producer sidecar is already extensive
/// and source-unit exact, so no reconstruction or stoichiometric conversion is
/// performed here.
pub fn accumulatePlantInternalRootShoot(
    ledger: *Ledger,
    activity: *const plant_internal.State,
    active_soil_layer_count: []const usize,
) !void {
    if (activity.cell_count != ledger.layout.cell_count or
        activity.soil_layer_count != ledger.layout.soil_layer_capacity or
        activity.canopy_to_root.len != try ledger.layout.soilCount() or
        activity.root_to_canopy.len != try ledger.layout.soilCount() or
        active_soil_layer_count.len != activity.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{
        .allocator = ledger.allocator,
        .layout = ledger.layout,
        .activity = candidate_values,
    };
    for (0..activity.cell_count) |cell| for (0..activity.soil_layer_count) |layer| {
        const flat = cell * activity.soil_layer_count + layer;
        const canopy_to_root = try plantInternalTransfer(activity.canopy_to_root[flat]);
        const root_to_canopy = try plantInternalTransfer(activity.root_to_canopy[flat]);
        if (active_soil_layer_count[cell] > activity.soil_layer_count)
            return error.InvalidActiveSoilLayerCount;
        if (layer >= active_soil_layer_count[cell]) {
            if (!std.meta.eql(canopy_to_root, hourly.IntercellTransfer{}) or
                !std.meta.eql(root_to_canopy, hourly.IntercellTransfer{}))
                return error.InactiveLayerConservationActivity;
            continue;
        }
        const canopy: ScopeAddress = .{ .kind = .canopy, .cell = cell };
        const root: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = layer };
        if (!std.meta.eql(canopy_to_root, hourly.IntercellTransfer{}))
            try candidate.accumulateTransfer(canopy, root, canopy_to_root);
        if (!std.meta.eql(root_to_canopy, hourly.IntercellTransfer{}))
            try candidate.accumulateTransfer(root, canopy, root_to_canopy);
    };
    @memcpy(ledger.activity, candidate.activity);
}

fn plantInternalTransfer(transfer: plant_internal.Transfer) !hourly.IntercellTransfer {
    inline for (.{ transfer.carbon_g_c, transfer.nitrogen_g_n, transfer.phosphorus_g_p }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLayerConservationActivity;
    for (transfer.salt_mol) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLayerConservationActivity;
    return .{
        .carbon_g = transfer.carbon_g_c,
        .nitrogen_g = transfer.nitrogen_g_n,
        .phosphorus_g = transfer.phosphorus_g_p,
        .aluminum_mol = transfer.salt_mol[0],
        .iron_mol = transfer.salt_mol[1],
        .calcium_mol = transfer.salt_mol[2],
        .magnesium_mol = transfer.salt_mol[3],
        .sodium_mol = transfer.salt_mol[4],
        .potassium_mol = transfer.salt_mol[5],
        .sulfur_mol = transfer.salt_mol[6],
        .chloride_mol = transfer.salt_mol[7],
    };
}

/// Maps the atmosphere router's already-disjoint accepted fragments to their
/// authoritative local owners. No precipitation, chemistry, vapor, or canopy
/// drainage term is reconstructed here; doing so would lose the producer's
/// actual snow/surface/topsoil destination and could double-book drainage as
/// an atmospheric input.
pub fn accumulateAcceptedAtmosphericActivity(
    ledger: *Ledger,
    active_soil_layer_count: []const usize,
    active_snow_by_layer: []const bool,
    activities: []const atmospheric_local.CellActivity,
) !void {
    if (active_soil_layer_count.len != ledger.layout.cell_count or
        active_snow_by_layer.len != try ledger.layout.snowCount() or
        activities.len != ledger.layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (activities, 0..) |activity, cell| {
        const top_snow = cell * ledger.layout.snow_layer_capacity;
        const snow_address: ScopeAddress = .{ .kind = .snow_layer, .cell = cell, .layer = 0 };
        const surface_address: ScopeAddress = .{ .kind = .surface, .cell = cell };
        const topsoil_address: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = 0 };
        const canopy_address: ScopeAddress = .{ .kind = .canopy, .cell = cell };
        if (!active_snow_by_layer[top_snow] and
            !std.meta.eql(activity.top_snow_external, hourly.BoundaryActivity{}))
            return error.InactiveLayerConservationActivity;
        if (active_soil_layer_count[cell] == 0 and
            !std.meta.eql(activity.topsoil_external, hourly.BoundaryActivity{}))
            return error.InactiveLayerConservationActivity;
        try candidate.accumulate(snow_address, activity.top_snow_external);
        try candidate.accumulate(surface_address, activity.surface_external);
        try candidate.accumulate(topsoil_address, activity.topsoil_external);
        if (!std.meta.eql(activity.canopy_to_top_snow, hourly.IntercellTransfer{})) {
            if (!active_snow_by_layer[top_snow]) return error.InactiveLayerConservationActivity;
            try candidate.accumulateTransfer(canopy_address, snow_address, activity.canopy_to_top_snow);
        }
        if (!std.meta.eql(activity.canopy_to_surface, hourly.IntercellTransfer{}))
            try candidate.accumulateTransfer(canopy_address, surface_address, activity.canopy_to_surface);
        if (!std.meta.eql(activity.canopy_to_topsoil, hourly.IntercellTransfer{})) {
            if (active_soil_layer_count[cell] == 0) return error.InactiveLayerConservationActivity;
            try candidate.accumulateTransfer(canopy_address, topsoil_address, activity.canopy_to_topsoil);
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// The runoff producer already separates gross horizontal credits/debits and
/// open-boundary exports after its accepted aqueous transaction. All those
/// owners live in the litter/suspended surface scope; copying that exact
/// activity here prevents horizontal cancellation within a column or domain.
pub fn accumulateSurfaceRunoffActivity(
    ledger: *Ledger,
    accepted_by_cell: []const hourly.BoundaryActivity,
) !void {
    if (accepted_by_cell.len != ledger.layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{
        .allocator = ledger.allocator,
        .layout = ledger.layout,
        .activity = candidate_values,
    };
    for (accepted_by_cell, 0..) |activity, cell|
        try candidate.accumulate(.{ .kind = .surface, .cell = cell }, activity);
    @memcpy(ledger.activity, candidate.activity);
}

/// Reuses the canonical erosion reducer to retain accepted horizontal
/// suspended-material credits/debits and open-boundary exports in each
/// surface scope. Local detachment and pond settling are separate paired
/// transfers and are therefore not reconstructed here.
pub fn accumulateSurfaceErosionRoutingActivity(
    ledger: *Ledger,
    columns: usize,
    rows: usize,
    organic: *const organic_state.State,
    organic_workspace: *const eroded_constituents.PackedWorkspace,
    fertilizer_workspace: *const eroded_constituents.PackedWorkspace,
    mineral_fertilizer_workspace: *const eroded_constituents.PackedWorkspace,
    chemistry_workspace: *const eroded_constituents.PackedWorkspace,
    mineral_workspace: *const eroded_constituents.PackedWorkspace,
    carbon_g_per_mol: f64,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    tolerances: hourly.ErosionAccountingTolerances,
) !void {
    const cell_count = std.math.mul(usize, columns, rows) catch
        return error.LayerConservationActivityDimensionMismatch;
    if (cell_count != ledger.layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    var routed = try hourly.BoundaryLedger.init(ledger.allocator, cell_count);
    defer routed.deinit();
    try hourly.accumulateErosionTransport(
        &routed,
        columns,
        rows,
        organic,
        organic_workspace,
        fertilizer_workspace,
        mineral_fertilizer_workspace,
        chemistry_workspace,
        mineral_workspace,
        carbon_g_per_mol,
        nitrogen_g_per_mol,
        phosphorus_g_per_mol,
        tolerances,
    );
    try accumulateSurfaceRunoffActivity(ledger, routed.cells);
}

pub const SedimentMolarMassesGPerMol = struct {
    carbon: f64,
    nitrogen: f64,
    phosphorus: f64,

    fn validate(self: SedimentMolarMassesGPerMol) !void {
        inline for (std.meta.fields(SedimentMolarMassesGPerMol)) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value <= 0)
                return error.InvalidLayerConservationMolarMass;
        }
    }
};

/// Maps the accepted local detachment/deposition transaction between its
/// actual logical soil layer and the suspended surface owner. The packed
/// producer vector is converted by the canonical suspended-inventory
/// stoichiometry, never by a duplicate erosion table.
pub fn accumulateSuspendedLocalExchange(
    ledger: *Ledger,
    state: *const suspended.State,
    organic_profile: *const organic_state.State,
    active_soil_layer_count: []const usize,
    molar_mass: SedimentMolarMassesGPerMol,
) !void {
    try molar_mass.validate();
    try state.validate();
    if (state.cell_count != ledger.layout.cell_count or
        state.local_exchange_soil_layer_by_cell.len != state.cell_count or
        state.local_sediment_to_suspension_megagrams.len != state.cell_count or
        state.local_transfer_to_suspension.len != try std.math.mul(usize, state.cell_count, state.component_count) or
        active_soil_layer_count.len != state.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    const magnitudes = try ledger.allocator.alloc(f64, state.component_count);
    defer ledger.allocator.free(magnitudes);
    for (0..state.cell_count) |cell| {
        const active_soil = active_soil_layer_count[cell];
        if (active_soil > ledger.layout.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        const signed_sediment = state.local_sediment_to_suspension_megagrams[cell];
        if (!std.math.isFinite(signed_sediment))
            return error.InvalidLayerConservationActivity;
        const first = cell * state.component_count;
        var any_component = false;
        for (state.local_transfer_to_suspension[first .. first + state.component_count], 0..) |signed_amount, component| {
            if (!std.math.isFinite(signed_amount) or
                (signed_amount != 0 and (signed_sediment == 0 or std.math.signbit(signed_amount) != std.math.signbit(signed_sediment))))
                return error.InvalidLayerConservationActivity;
            magnitudes[component] = @abs(signed_amount);
            any_component = any_component or signed_amount != 0;
        }
        if (signed_sediment == 0) {
            if (any_component) return error.InvalidLayerConservationActivity;
            continue;
        }
        if (!any_component) return error.InvalidLayerConservationActivity;
        const layer = state.local_exchange_soil_layer_by_cell[cell];
        if (layer >= active_soil) return error.InactiveLayerConservationActivity;
        const storage = try inventory.aggregateSuspendedComponentAmounts(
            state.layout,
            organic_profile,
            molar_mass.carbon,
            molar_mass.nitrogen,
            molar_mass.phosphorus,
            magnitudes,
        );
        const transfer = try storageToIntercellTransfer(storage);
        const soil_address: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = layer };
        const surface_address: ScopeAddress = .{ .kind = .surface, .cell = cell };
        if (signed_sediment > 0)
            try candidate.accumulateTransfer(soil_address, surface_address, transfer)
        else
            try candidate.accumulateTransfer(surface_address, soil_address, transfer);
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Books the three sequential pond transactions from their producer-atomic
/// sidecars: surface particulate settling, deeper soil-to-soil settling, and
/// the remaining full-domain surface transfer. Each actual logical receiver
/// is preserved, so no top-layer inference can hide a layer-local defect.
pub fn accumulatePondAcceptedTransfers(
    ledger: *Ledger,
    active_soil_layer_count: []const usize,
    particulate_surface: pond_conservation.CellSidecar,
    particulate_soil: pond_conservation.SoilLayerSidecar,
    full_domain_surface: pond_conservation.CellSidecar,
    molar_mass: SedimentMolarMassesGPerMol,
) !void {
    try molar_mass.validate();
    if (active_soil_layer_count.len != ledger.layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    try particulate_surface.validateDimensions(ledger.layout.cell_count);
    try full_domain_surface.validateDimensions(ledger.layout.cell_count);
    try particulate_soil.validateDimensions(try ledger.layout.soilCount());
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    try accumulatePondSurfaceSidecar(&candidate, active_soil_layer_count, particulate_surface, molar_mass);
    try accumulatePondSoilSidecar(&candidate, active_soil_layer_count, particulate_soil, molar_mass);
    try accumulatePondSurfaceSidecar(&candidate, active_soil_layer_count, full_domain_surface, molar_mass);
    @memcpy(ledger.activity, candidate.activity);
}

/// Publishes accepted fertilizer inputs at their producer-resolved litter or
/// depth-selected soil owner. Irrigation is intentionally absent: its actual
/// snow/surface/topsoil destination belongs exclusively to the atmosphere
/// router and must never be booked a second time as management activity.
pub fn accumulateFertilizerLocalActivity(
    ledger: *Ledger,
    sidecar: *const fertilizer_dispatch.LocalActivityState,
    active_soil_layer_count: []const usize,
) !void {
    const soil_count = try ledger.layout.soilCount();
    if (sidecar.cell_count != ledger.layout.cell_count or
        sidecar.soil_layer_capacity != ledger.layout.soil_layer_capacity or
        sidecar.surface_by_cell.len != ledger.layout.cell_count or
        sidecar.soil_by_layer.len != soil_count or
        active_soil_layer_count.len != ledger.layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (0..ledger.layout.cell_count) |cell| {
        const active_soil = active_soil_layer_count[cell];
        if (active_soil > ledger.layout.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        try candidate.accumulate(
            .{ .kind = .surface, .cell = cell },
            try fertilizerBoundaryActivity(sidecar.surface_by_cell[cell]),
        );
        for (0..ledger.layout.soil_layer_capacity) |layer| {
            const fragment = sidecar.soil_by_layer[cell * ledger.layout.soil_layer_capacity + layer];
            const activity = try fertilizerBoundaryActivity(fragment);
            if (layer >= active_soil) {
                if (!std.meta.eql(activity, hourly.BoundaryActivity{}))
                    return error.InactiveLayerConservationActivity;
                continue;
            }
            try candidate.accumulate(.{ .kind = .soil_layer, .cell = cell, .layer = layer }, activity);
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

fn fertilizerBoundaryActivity(fragment: fertilizer_dispatch.FertilizerActivity) !hourly.BoundaryActivity {
    inline for (std.meta.fields(fertilizer_dispatch.FertilizerActivity)) |field| {
        const value = @field(fragment, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLayerConservationActivity;
    }
    return .{
        .carbon_input_g = fragment.carbon_g_c,
        .nitrogen_input_g = fragment.nitrogen_g_n,
        .phosphorus_input_g = fragment.phosphorus_g_p,
        .aluminum_input_mol = fragment.aluminum_mol,
        .iron_input_mol = fragment.iron_mol,
        .calcium_input_mol = fragment.calcium_mol,
        .magnesium_input_mol = fragment.magnesium_mol,
        .sodium_input_mol = fragment.sodium_mol,
        .potassium_input_mol = fragment.potassium_mol,
        .sulfur_input_mol = fragment.sulfur_mol,
        .silicon_input_mol = fragment.silicon_mol,
    };
}

fn accumulatePondSurfaceSidecar(
    ledger: *Ledger,
    active_soil_layer_count: []const usize,
    sidecar: pond_conservation.CellSidecar,
    molar_mass: SedimentMolarMassesGPerMol,
) !void {
    for (0..ledger.layout.cell_count) |cell| {
        const active_soil = active_soil_layer_count[cell];
        if (active_soil > ledger.layout.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        const transfer = sidecar.transfer[cell];
        try transfer.validate();
        if (!sidecar.active[cell]) {
            if (!std.meta.eql(transfer, pond_conservation.Transfer{}))
                return error.InactiveLayerConservationActivity;
            continue;
        }
        const destination = sidecar.destination_soil_layer[cell];
        if (destination >= active_soil)
            return error.InactiveLayerConservationActivity;
        try ledger.accumulateTransfer(
            .{ .kind = .surface, .cell = cell },
            .{ .kind = .soil_layer, .cell = cell, .layer = destination },
            try pondTransferToIntercellTransfer(transfer, molar_mass),
        );
    }
}

fn accumulatePondSoilSidecar(
    ledger: *Ledger,
    active_soil_layer_count: []const usize,
    sidecar: pond_conservation.SoilLayerSidecar,
    molar_mass: SedimentMolarMassesGPerMol,
) !void {
    for (0..ledger.layout.cell_count) |cell| {
        const active_soil = active_soil_layer_count[cell];
        if (active_soil > ledger.layout.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        for (0..ledger.layout.soil_layer_capacity) |source| {
            const flat = cell * ledger.layout.soil_layer_capacity + source;
            const transfer = sidecar.transfer_by_source[flat];
            try transfer.validate();
            if (!sidecar.active_by_source[flat]) {
                if (!std.meta.eql(transfer, pond_conservation.Transfer{}))
                    return error.InactiveLayerConservationActivity;
                continue;
            }
            const destination = sidecar.destination_soil_layer_by_source[flat];
            if (source >= active_soil or destination >= active_soil or source == destination)
                return error.InactiveLayerConservationActivity;
            try ledger.accumulateTransfer(
                .{ .kind = .soil_layer, .cell = cell, .layer = source },
                .{ .kind = .soil_layer, .cell = cell, .layer = destination },
                try pondTransferToIntercellTransfer(transfer, molar_mass),
            );
        }
    }
}

fn pondTransferToIntercellTransfer(
    transfer: pond_conservation.Transfer,
    molar_mass: SedimentMolarMassesGPerMol,
) !hourly.IntercellTransfer {
    try transfer.validate();
    return .{
        .water_m3 = transfer.water_m3,
        .heat_megajoules = transfer.heat_megajoules,
        .oxygen_g = transfer.oxygen_g,
        .hydrogen_g = transfer.hydrogen_g,
        .carbon_g = try addNonnegativeAmounts(&.{ transfer.carbon_g, try multiplyNonnegative(transfer.carbon_mol, molar_mass.carbon) }),
        .nitrogen_g = try addNonnegativeAmounts(&.{ transfer.nitrogen_g, try multiplyNonnegative(transfer.nitrogen_mol, molar_mass.nitrogen) }),
        .phosphorus_g = try addNonnegativeAmounts(&.{ transfer.phosphorus_g, try multiplyNonnegative(transfer.phosphorus_mol, molar_mass.phosphorus) }),
        .aluminum_mol = transfer.aluminum_mol,
        .iron_mol = transfer.iron_mol,
        .calcium_mol = transfer.calcium_mol,
        .magnesium_mol = transfer.magnesium_mol,
        .sodium_mol = transfer.sodium_mol,
        .potassium_mol = transfer.potassium_mol,
        .sulfur_mol = transfer.sulfur_mol,
        .chloride_mol = transfer.chloride_mol,
        .silicon_mol = transfer.silicon_mol,
        .sand_megagrams = transfer.sand_megagrams,
        .silt_megagrams = transfer.silt_megagrams,
        .clay_megagrams = transfer.clay_megagrams,
        .cation_exchange_capacity_mol = transfer.cation_exchange_capacity_mol,
        .anion_exchange_capacity_mol = transfer.anion_exchange_capacity_mol,
    };
}

fn storageToIntercellTransfer(storage: inventory.Storage) !hourly.IntercellTransfer {
    try storage.validate();
    return .{
        .water_m3 = storage.water_m3,
        .heat_megajoules = storage.heat_megajoules,
        .oxygen_g = storage.oxygen_g,
        .hydrogen_g = storage.hydrogen_g,
        .carbon_g = try addNonnegativeAmounts(&.{ storage.residue_carbon_g, storage.organic_carbon_g, storage.carbon_dioxide_carbon_g, storage.plant_carbon_g }),
        .nitrogen_g = try addNonnegativeAmounts(&.{ storage.residue_nitrogen_g, storage.organic_nitrogen_g, storage.dinitrogen_nitrogen_g, storage.ammonium_nitrogen_g, storage.nitrate_nitrogen_g, storage.plant_nitrogen_g }),
        .phosphorus_g = try addNonnegativeAmounts(&.{ storage.residue_phosphorus_g, storage.organic_phosphorus_g, storage.phosphate_phosphorus_g, storage.plant_phosphorus_g }),
        .aluminum_mol = storage.aluminum_mol,
        .iron_mol = storage.iron_mol,
        .calcium_mol = storage.calcium_mol,
        .magnesium_mol = storage.magnesium_mol,
        .sodium_mol = storage.sodium_mol,
        .potassium_mol = storage.potassium_mol,
        .sulfur_mol = storage.sulfur_mol,
        .chloride_mol = storage.chloride_mol,
        .silicon_mol = storage.silicon_mol,
        .sand_megagrams = storage.sand_megagrams,
        .silt_megagrams = storage.silt_megagrams,
        .clay_megagrams = storage.clay_megagrams,
        .rock_additive = storage.rock_additive,
        .cation_exchange_capacity_mol = storage.cation_exchange_capacity_mol,
        .anion_exchange_capacity_mol = storage.anion_exchange_capacity_mol,
    };
}

fn multiplyNonnegative(left: f64, right: f64) !f64 {
    const result = left * right;
    if (!std.math.isFinite(result) or result < 0)
        return error.InvalidLayerConservationActivity;
    return result;
}

fn addNonnegativeAmounts(values: []const f64) !f64 {
    var result: f64 = 0;
    for (values) |value| {
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLayerConservationActivity;
        result += value;
        if (!std.math.isFinite(result)) return error.LayerConservationActivityOverflow;
    }
    return result;
}

/// Books every accepted soil water/phase-vapor and heat face published by
/// WATSUB. Positive face flux is first scope -> second scope, matching the
/// accepted transport arrays and F77 FLW/HFLW directional convention. All
/// axes are required: a horizontal face also crosses a `(cell, layer)` scope.
pub fn accumulateSoilWaterHeatFaces(
    ledger: *Ledger,
    faces: *const hydrology.SoilFaces,
) !void {
    try validateSoilFaces(faces, ledger.layout);
    // Preflight every face against a private ledger. A malformed late face
    // therefore cannot retain a valid earlier transfer.
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{
        .allocator = ledger.allocator,
        .layout = ledger.layout,
        .activity = candidate_values,
    };
    for (0..faces.direction_axis.len) |face| {
        if (!faces.active_by_face[face]) continue;
        const topology = faces.micropore_faces[face];
        const water = faces.micropore_water_flux_m3_per_step[face] +
            faces.macropore_water_flux_m3_per_step[face] +
            faces.vapor_flux_m3_per_step[face];
        const heat = faces.heat_flux_megajoules_per_step[face];
        if (!std.math.isFinite(water) or !std.math.isFinite(heat))
            return error.InvalidLayerConservationActivity;
        if (water != 0) try accumulateFlatSoilTransfer(
            &candidate,
            topology.first_cell,
            topology.second_cell,
            water,
            .{ .water_m3 = @abs(water) },
        );
        if (heat != 0) try accumulateFlatSoilTransfer(
            &candidate,
            topology.first_cell,
            topology.second_cell,
            heat,
            .{ .heat_megajoules = @abs(heat) },
        );
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Books all accepted aqueous faces in element units. Carbon and phosphorus
/// use the same runscript molar masses as the authoritative cell/domain gate;
/// each remaining ion is reduced by its exact chemical formula.
pub fn accumulateAqueousFaces(
    ledger: *Ledger,
    faces: *const hydrology.SoilFaces,
    micropore_face_flux_mol: []const f64,
    macropore_face_flux_mol: []const f64,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !void {
    try validateSoilFaces(faces, ledger.layout);
    if (!std.math.isFinite(carbon_g_per_mol) or carbon_g_per_mol <= 0 or
        !std.math.isFinite(phosphorus_g_per_mol) or phosphorus_g_per_mol <= 0)
        return error.InvalidLayerConservationMolarMass;
    const component_count = try std.math.mul(
        usize,
        faces.direction_axis.len,
        solute_species.AqueousSpecies.count,
    );
    if (micropore_face_flux_mol.len != component_count or
        macropore_face_flux_mol.len != component_count)
        return error.LayerConservationActivityDimensionMismatch;

    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{
        .allocator = ledger.allocator,
        .layout = ledger.layout,
        .activity = candidate_values,
    };
    for (0..faces.direction_axis.len) |face| {
        if (!faces.active_by_face[face]) continue;
        const topology = faces.micropore_faces[face];
        const start = face * solute_species.AqueousSpecies.count;
        for (0..solute_species.AqueousSpecies.count) |species_index| {
            const flux = micropore_face_flux_mol[start + species_index] +
                macropore_face_flux_mol[start + species_index];
            if (!std.math.isFinite(flux)) return error.InvalidLayerConservationActivity;
            if (flux != 0) {
                const formula = surface_aqueous.formula(@enumFromInt(species_index));
                const magnitude = @abs(flux);
                const transfer: hourly.IntercellTransfer = .{
                    .carbon_g = magnitude * formula.carbon_mol * carbon_g_per_mol,
                    .phosphorus_g = magnitude * formula.phosphorus_mol * phosphorus_g_per_mol,
                    .aluminum_mol = magnitude * formula.aluminum_mol,
                    .iron_mol = magnitude * formula.iron_mol,
                    .calcium_mol = magnitude * formula.calcium_mol,
                    .magnesium_mol = magnitude * formula.magnesium_mol,
                    .sodium_mol = magnitude * formula.sodium_mol,
                    .potassium_mol = magnitude * formula.potassium_mol,
                    .sulfur_mol = magnitude * formula.sulfur_mol,
                    .chloride_mol = magnitude * formula.chloride_mol,
                    .silicon_mol = magnitude * formula.silicon_mol,
                };
                try accumulateFlatSoilTransfer(
                    &candidate,
                    topology.first_cell,
                    topology.second_cell,
                    flux,
                    transfer,
                );
            }
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Books every accepted dry-gas face. Species remain separate until their
/// direction has been published, so opposing species cannot erase throughput.
pub fn accumulateGasFaces(
    ledger: *Ledger,
    state: *const gas_transport_step.State,
) !void {
    const layer_count = try ledger.layout.soilCount();
    const expected = try std.math.mul(usize, state.accepted_faces.len, gas_transport.species_count);
    if (state.accepted_face_flux_g_per_h.len != expected)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (state.accepted_faces, 0..) |face, face_index| {
        if (face.first_cell >= layer_count or face.second_cell >= layer_count or
            face.first_cell == face.second_cell)
            return error.InvalidLayerConservationFaceTopology;
        const start = face_index * gas_transport.species_count;
        inline for (@typeInfo(gas_transport.Species).@"enum".fields) |field| {
            const flux = state.accepted_face_flux_g_per_h[start + field.value];
            if (!std.math.isFinite(flux)) return error.InvalidLayerConservationActivity;
            if (flux != 0) {
                const transfer: hourly.IntercellTransfer = switch (@as(gas_transport.Species, @enumFromInt(field.value))) {
                    .carbon_dioxide, .methane => .{ .carbon_g = @abs(flux) },
                    .oxygen => .{ .oxygen_g = @abs(flux) },
                    .nitrogen, .nitrous_oxide, .ammonia => .{ .nitrogen_g = @abs(flux) },
                    .hydrogen => .{ .hydrogen_g = @abs(flux) },
                };
                try accumulateFlatSoilTransfer(&candidate, face.first_cell, face.second_cell, flux, transfer);
            }
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Exact accepted REDIST bubbling redistribution. Inputs and outputs are the
/// paired legs accumulated from the coupled gas solver while its per-substep
/// `LL=MIN(L,LG)` receiver map is still authoritative. This is layer-local
/// activity only; bubbling with a modeled receiver is internal to the shared
/// horizontal column and therefore never enters cell/domain boundary ledgers.
pub fn accumulateSoilGasBubbleActivity(
    ledger: *Ledger,
    active_soil_layer_count: []const usize,
    input_by_layer: []const hourly.IntercellTransfer,
    output_by_layer: []const hourly.IntercellTransfer,
) !void {
    const soil_count = try ledger.layout.soilCount();
    if (active_soil_layer_count.len != ledger.layout.cell_count or
        input_by_layer.len != soil_count or output_by_layer.len != soil_count)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{
        .allocator = ledger.allocator,
        .layout = ledger.layout,
        .activity = candidate_values,
    };
    for (active_soil_layer_count, 0..) |active, cell| {
        if (active > ledger.layout.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        const first = cell * ledger.layout.soil_layer_capacity;
        for (0..ledger.layout.soil_layer_capacity) |layer| {
            const input = input_by_layer[first + layer];
            const output = output_by_layer[first + layer];
            try validateTransfer(input);
            try validateTransfer(output);
            if (layer >= active) {
                if (!std.meta.eql(input, hourly.IntercellTransfer{}) or
                    !std.meta.eql(output, hourly.IntercellTransfer{}))
                    return error.InactiveLayerConservationActivity;
                continue;
            }
            const address: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = layer };
            if (!std.meta.eql(input, hourly.IntercellTransfer{}))
                try candidate.accumulate(address, transferActivity(input, .input));
            if (!std.meta.eql(output, hourly.IntercellTransfer{}))
                try candidate.accumulate(address, transferActivity(output, .output));
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Books every accepted dissolved-gas face. Ammonia is deliberately excluded:
/// the mineral-N owner carries ZNH3S/ZNH3B and the dissolved-gas slot is only
/// a solver mirror, exactly as in the authoritative storage census.
pub fn accumulateDissolvedGasFaces(
    ledger: *Ledger,
    faces: *const hydrology.SoilFaces,
    micropore_face_flux_g: []const f64,
    macropore_face_flux_g: []const f64,
) !void {
    try validateSoilFaces(faces, ledger.layout);
    const expected = try std.math.mul(usize, faces.direction_axis.len, gas_transport.species_count);
    if (micropore_face_flux_g.len != expected or macropore_face_flux_g.len != expected)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (faces.micropore_faces, 0..) |face, face_index| {
        if (!faces.active_by_face[face_index]) continue;
        const start = face_index * gas_transport.species_count;
        inline for (@typeInfo(gas_transport.Species).@"enum".fields) |field| {
            const species: gas_transport.Species = @enumFromInt(field.value);
            if (species == .ammonia) continue;
            const flux = micropore_face_flux_g[start + field.value] +
                macropore_face_flux_g[start + field.value];
            if (!std.math.isFinite(flux)) return error.InvalidLayerConservationActivity;
            if (flux != 0) {
                const transfer: hourly.IntercellTransfer = switch (species) {
                    .carbon_dioxide, .methane => .{ .carbon_g = @abs(flux) },
                    .oxygen => .{ .oxygen_g = @abs(flux) },
                    .nitrogen, .nitrous_oxide => .{ .nitrogen_g = @abs(flux) },
                    .hydrogen => .{ .hydrogen_g = @abs(flux) },
                    .ammonia => unreachable,
                };
                try accumulateFlatSoilTransfer(&candidate, face.first_cell, face.second_cell, flux, transfer);
            }
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Exact accepted dry-gas exchange at the atmosphere and physical subsurface
/// boundaries. TRNSFR 3320--3361 and 3643--3684 retain litter and soil surface
/// fluxes separately; REDIST 4465--4507 consumes both without changing their
/// owners. Soil transport publishes each boundary flux at its owning layer;
/// the independent litter gas solve publishes to the surface scope.
/// The three producer streams are kept direction-separated so simultaneous
/// uptake and emission cannot disappear before local conservation acceptance.
pub fn accumulateSoilSurfaceGasAtmosphere(
    ledger: *Ledger,
    active_soil_layer_count_by_cell: []const usize,
    soil_atmospheric_flux_g: []const f64,
    soil_subsurface_flux_g: []const f64,
    litter_atmospheric_flux_g: []const f64,
) !void {
    const soil_count = try ledger.layout.soilCount();
    const soil_components = try std.math.mul(usize, soil_count, gas_transport.species_count);
    const litter_components = try std.math.mul(usize, ledger.layout.cell_count, gas_transport.species_count);
    if (active_soil_layer_count_by_cell.len != ledger.layout.cell_count or
        soil_atmospheric_flux_g.len != soil_components or
        soil_subsurface_flux_g.len != soil_components or
        litter_atmospheric_flux_g.len != litter_components)
        return error.LayerConservationActivityDimensionMismatch;

    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{
        .allocator = ledger.allocator,
        .layout = ledger.layout,
        .activity = candidate_values,
    };
    for (active_soil_layer_count_by_cell, 0..) |active_layers, cell| {
        if (active_layers == 0 or active_layers > ledger.layout.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        for (0..ledger.layout.soil_layer_capacity) |local_layer| {
            const flat = cell * ledger.layout.soil_layer_capacity + local_layer;
            const active = local_layer < active_layers;
            const address: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = local_layer };
            inline for (@typeInfo(gas_transport.Species).@"enum".fields) |field| {
                const species: gas_transport.Species = @enumFromInt(field.value);
                const component = flat * gas_transport.species_count + field.value;
                inline for (.{
                    soil_atmospheric_flux_g[component],
                    soil_subsurface_flux_g[component],
                }) |signed| try accumulateExternalGain(
                    &candidate,
                    address,
                    active,
                    signed,
                    gasElementTransfer(species, @abs(signed)),
                );
            }
        }
        const surface: ScopeAddress = .{ .kind = .surface, .cell = cell };
        inline for (@typeInfo(gas_transport.Species).@"enum".fields) |field| {
            const species: gas_transport.Species = @enumFromInt(field.value);
            const signed = litter_atmospheric_flux_g[cell * gas_transport.species_count + field.value];
            try accumulateExternalGain(
                &candidate,
                surface,
                true,
                signed,
                gasElementTransfer(species, @abs(signed)),
            );
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

fn gasElementTransfer(species: gas_transport.Species, amount_g: f64) hourly.IntercellTransfer {
    return switch (species) {
        .carbon_dioxide, .methane => .{ .carbon_g = amount_g },
        .oxygen => .{ .oxygen_g = amount_g },
        .nitrogen, .nitrous_oxide, .ammonia => .{ .nitrogen_g = amount_g },
        .hydrogen => .{ .hydrogen_g = amount_g },
    };
}

/// Books all accepted DOC/DON/DOP/acetate faces in the exact component order
/// owned by the organic transport state.
pub fn accumulateOrganicFaces(
    ledger: *Ledger,
    faces: *const hydrology.SoilFaces,
    micropore_face_flux_g: []const f64,
    macropore_face_flux_g: []const f64,
) !void {
    try validateSoilFaces(faces, ledger.layout);
    const expected = try std.math.mul(usize, faces.direction_axis.len, organic_transport.component_count);
    if (micropore_face_flux_g.len != expected or macropore_face_flux_g.len != expected)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (faces.micropore_faces, 0..) |face, face_index| {
        if (!faces.active_by_face[face_index]) continue;
        const start = face_index * organic_transport.component_count;
        for (0..organic_transport.component_count) |component| {
            const flux = micropore_face_flux_g[start + component] +
                macropore_face_flux_g[start + component];
            if (!std.math.isFinite(flux)) return error.InvalidLayerConservationActivity;
            if (flux == 0) continue;
            const transfer: hourly.IntercellTransfer = switch (component % organic_transport.components_per_substrate) {
                0, 3 => .{ .carbon_g = @abs(flux) },
                1 => .{ .nitrogen_g = @abs(flux) },
                2 => .{ .phosphorus_g = @abs(flux) },
                else => unreachable,
            };
            try accumulateFlatSoilTransfer(&candidate, face.first_cell, face.second_cell, flux, transfer);
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Books all accepted mineral-N faces after the matrix and macropore species
/// ledgers are combined. All species are mol N, converted with the runscript
/// nitrogen molar mass before entering the layer ledger.
pub fn accumulateMineralNitrogenFaces(
    ledger: *Ledger,
    faces: *const hydrology.SoilFaces,
    micropore_face_flux_mol: []const f64,
    macropore_face_flux_mol: []const f64,
    nitrogen_g_per_mol: f64,
) !void {
    try validateSoilFaces(faces, ledger.layout);
    if (!std.math.isFinite(nitrogen_g_per_mol) or nitrogen_g_per_mol <= 0)
        return error.InvalidLayerConservationMolarMass;
    const expected = try std.math.mul(usize, faces.direction_axis.len, mineral_nitrogen_transport.species_count);
    if (micropore_face_flux_mol.len != expected or macropore_face_flux_mol.len != expected)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (faces.micropore_faces, 0..) |face, face_index| {
        if (!faces.active_by_face[face_index]) continue;
        const start = face_index * mineral_nitrogen_transport.species_count;
        for (0..mineral_nitrogen_transport.species_count) |species| {
            const flux = micropore_face_flux_mol[start + species] +
                macropore_face_flux_mol[start + species];
            if (!std.math.isFinite(flux)) return error.InvalidLayerConservationActivity;
            const signed_g = flux * nitrogen_g_per_mol;
            if (!std.math.isFinite(signed_g)) return error.LayerConservationActivityOverflow;
            if (signed_g != 0) try accumulateFlatSoilTransfer(
                &candidate,
                face.first_cell,
                face.second_cell,
                signed_g,
                .{ .nitrogen_g = @abs(signed_g) },
            );
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Accepted external exchange for every authoritative soil-layer owner.
/// Water and heat are gain-positive. Aqueous, organic and dissolved-gas
/// producers publish signed net input. Mineral N is the producer's explicit
/// nonnegative boundary export. Species/components are direction-separated
/// before element reduction, so equal-and-opposite carriers cannot disappear
/// inside a layer. The explicit Richards matrix source is intentionally absent:
/// it is subsurface irrigation and belongs to the management-transfer family.
pub const SoilExternalBoundaries = struct {
    active_by_layer: []const bool,
    boundary_water_gain_m3: []const f64,
    boundary_heat_gain_megajoules: []const f64,
    aqueous_boundary_net_input_mol: []const f64,
    organic_boundary_net_input_g: []const f64,
    mineral_nitrogen_boundary_export_g: []const f64,
    dissolved_gas_boundary_net_input_g: []const f64,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
};

/// Sensible heat carried by accepted Richards water across each exact soil
/// boundary owner. Positive is outward and negative inward. Keep this producer
/// separate from conductive/geothermal boundary heat so opposing gross
/// throughput cannot disappear through premature netting.
pub fn accumulateSoilExternalAdvectiveHeat(
    ledger: *Ledger,
    active_by_layer: []const bool,
    outward_heat_megajoules_by_layer: []const f64,
) !void {
    const layer_count = try ledger.layout.soilCount();
    if (active_by_layer.len != layer_count or
        outward_heat_megajoules_by_layer.len != layer_count)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (outward_heat_megajoules_by_layer, 0..) |outward, flat_layer| {
        if (!std.math.isFinite(outward)) return error.InvalidLayerConservationActivity;
        if (!active_by_layer[flat_layer]) {
            if (outward != 0) return error.InactiveLayerConservationActivity;
            continue;
        }
        if (outward == 0) continue;
        const address = try flatSoilAddress(ledger.layout, flat_layer);
        try candidate.accumulate(address, if (outward > 0)
            .{ .heat_output_megajoules = outward }
        else
            .{ .heat_input_megajoules = -outward });
    }
    @memcpy(ledger.activity, candidate.activity);
}

pub fn accumulateSoilExternalBoundaries(
    ledger: *Ledger,
    inputs: SoilExternalBoundaries,
) !void {
    @setEvalBranchQuota(10_000);
    const layer_count = try ledger.layout.soilCount();
    if (inputs.active_by_layer.len != layer_count or
        inputs.boundary_water_gain_m3.len != layer_count or
        inputs.boundary_heat_gain_megajoules.len != layer_count or
        inputs.mineral_nitrogen_boundary_export_g.len != layer_count or
        inputs.aqueous_boundary_net_input_mol.len != try std.math.mul(
            usize,
            layer_count,
            solute_species.AqueousSpecies.count,
        ) or
        inputs.organic_boundary_net_input_g.len != try std.math.mul(
            usize,
            layer_count,
            organic_transport.component_count,
        ) or
        inputs.dissolved_gas_boundary_net_input_g.len != try std.math.mul(
            usize,
            layer_count,
            gas_transport.species_count,
        ))
        return error.LayerConservationActivityDimensionMismatch;
    if (!std.math.isFinite(inputs.carbon_g_per_mol) or inputs.carbon_g_per_mol <= 0 or
        !std.math.isFinite(inputs.phosphorus_g_per_mol) or inputs.phosphorus_g_per_mol <= 0)
        return error.InvalidLayerConservationMolarMass;

    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{
        .allocator = ledger.allocator,
        .layout = ledger.layout,
        .activity = candidate_values,
    };
    for (0..layer_count) |flat_layer| {
        const address = try flatSoilAddress(ledger.layout, flat_layer);
        const active = inputs.active_by_layer[flat_layer];
        try accumulateExternalGain(
            &candidate,
            address,
            active,
            inputs.boundary_water_gain_m3[flat_layer],
            .{ .water_m3 = @abs(inputs.boundary_water_gain_m3[flat_layer]) },
        );
        try accumulateExternalGain(
            &candidate,
            address,
            active,
            inputs.boundary_heat_gain_megajoules[flat_layer],
            .{ .heat_megajoules = @abs(inputs.boundary_heat_gain_megajoules[flat_layer]) },
        );

        const aqueous_start = flat_layer * solute_species.AqueousSpecies.count;
        for (0..solute_species.AqueousSpecies.count) |species_index| {
            const signed = inputs.aqueous_boundary_net_input_mol[aqueous_start + species_index];
            const formula = surface_aqueous.formula(@enumFromInt(species_index));
            const amount = @abs(signed);
            try accumulateExternalGain(&candidate, address, active, signed, .{
                .carbon_g = amount * formula.carbon_mol * inputs.carbon_g_per_mol,
                .phosphorus_g = amount * formula.phosphorus_mol * inputs.phosphorus_g_per_mol,
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

        const organic_start = flat_layer * organic_transport.component_count;
        for (0..organic_transport.component_count) |component| {
            const signed = inputs.organic_boundary_net_input_g[organic_start + component];
            const amount = @abs(signed);
            const transfer: hourly.IntercellTransfer = switch (component % organic_transport.components_per_substrate) {
                0, 3 => .{ .carbon_g = amount },
                1 => .{ .nitrogen_g = amount },
                2 => .{ .phosphorus_g = amount },
                else => unreachable,
            };
            try accumulateExternalGain(&candidate, address, active, signed, transfer);
        }

        const mineral_export = inputs.mineral_nitrogen_boundary_export_g[flat_layer];
        if (!std.math.isFinite(mineral_export) or mineral_export < 0)
            return error.InvalidLayerConservationActivity;
        if (!active and mineral_export != 0)
            return error.InactiveLayerConservationActivity;
        if (mineral_export != 0) try candidate.accumulate(
            address,
            transferActivity(.{ .nitrogen_g = mineral_export }, .output),
        );

        const gas_start = flat_layer * gas_transport.species_count;
        inline for (@typeInfo(gas_transport.Species).@"enum".fields) |field| {
            const species: gas_transport.Species = @enumFromInt(field.value);
            const signed = inputs.dissolved_gas_boundary_net_input_g[gas_start + field.value];
            if (species == .ammonia) {
                if (!std.math.isFinite(signed)) return error.InvalidLayerConservationActivity;
                // This slot is the mineral-N phase-equilibrium mirror, never a
                // second transport owner.
                continue;
            }
            const transfer: hourly.IntercellTransfer = switch (species) {
                .carbon_dioxide, .methane => .{ .carbon_g = @abs(signed) },
                .oxygen => .{ .oxygen_g = @abs(signed) },
                .nitrogen, .nitrous_oxide => .{ .nitrogen_g = @abs(signed) },
                .hydrogen => .{ .hydrogen_g = @abs(signed) },
                .ammonia => unreachable,
            };
            try accumulateExternalGain(&candidate, address, active, signed, transfer);
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Publishes the accepted REDIST TUPWTR/TUPHT layer partition. Root water is
/// an internal soil--canopy transfer: negative source-sign water change moves
/// soil to canopy, while hydraulic return reverses that pair. The convective
/// enthalpy term retains the translated cell ledger's signed internal-energy
/// convention at the soil layer because plant water sensible heat is not an
/// authoritative canopy storage owner. Canopy atmospheric exchange later
/// removes the paired water input; no root-water mass is fabricated here.
pub fn accumulateRootWaterHeatUptake(
    ledger: *Ledger,
    active_soil_layer_count: []const usize,
    accepted_water_change_m3: []const f64,
    convective_water_heat_megajoules: []const f64,
) !void {
    if (active_soil_layer_count.len != ledger.layout.cell_count or
        accepted_water_change_m3.len != try ledger.layout.soilCount() or
        convective_water_heat_megajoules.len != accepted_water_change_m3.len)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{
        .allocator = ledger.allocator,
        .layout = ledger.layout,
        .activity = candidate_values,
    };
    for (active_soil_layer_count, 0..) |active_layers, cell| {
        if (active_layers > ledger.layout.soil_layer_capacity)
            return error.LayerConservationActivityDimensionMismatch;
        for (0..ledger.layout.soil_layer_capacity) |local_layer| {
            const flat = cell * ledger.layout.soil_layer_capacity + local_layer;
            const water = accepted_water_change_m3[flat];
            const heat = convective_water_heat_megajoules[flat];
            if (!std.math.isFinite(water) or !std.math.isFinite(heat))
                return error.InvalidLayerConservationActivity;
            if (local_layer >= active_layers) {
                if (water != 0 or heat != 0)
                    return error.InactiveLayerConservationActivity;
                continue;
            }
            if ((water == 0) != (heat == 0) or
                (water > 0 and heat < 0) or (water < 0 and heat > 0))
                return error.InvalidLayerConservationRootWaterHeatPair;
            const soil: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = local_layer };
            const canopy: ScopeAddress = .{ .kind = .canopy, .cell = cell };
            if (water < 0) try candidate.accumulateTransfer(
                soil,
                canopy,
                .{ .water_m3 = -water },
            ) else if (water > 0) try candidate.accumulateTransfer(
                canopy,
                soil,
                .{ .water_m3 = water },
            );
            if (heat != 0) try candidate.accumulate(soil, if (heat > 0)
                .{ .heat_internal_production_megajoules = heat }
            else
                .{ .heat_internal_consumption_megajoules = -heat });
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Exact EXTRACT root-gas layer activity. `T*FLA` is positive atmosphere to
/// root, while GROSUB withdrawal sidecars are non-positive root to atmosphere.
/// The two producers are direction-split independently so coincident uptake
/// and release cannot cancel before the local gate. Soil-root diffusion and
/// root aqueous-gaseous exchange stay within this same soil-layer scope and
/// therefore require no boundary entry. `TUPOXS/TUPOXP` are irreversible O2
/// consumption from inventoried soil/root pools and remain process-local.
pub const RootGasActivity = struct {
    active_soil_layer_count: []const usize,
    atmosphere_exchange_g_per_h_by_gas_and_layer: [root_atmosphere.gas_count][]const f64,
    withdrawal_loss_g_per_h_by_gas_and_layer: [root_withdrawal.gas_count][]const f64,
    soil_oxygen_uptake_g_o_per_h: []const f64,
    root_pool_oxygen_uptake_g_o_per_h: []const f64,
};

pub fn accumulateRootGasActivity(ledger: *Ledger, inputs: RootGasActivity) !void {
    const layer_count = try ledger.layout.soilCount();
    if (inputs.active_soil_layer_count.len != ledger.layout.cell_count or
        inputs.soil_oxygen_uptake_g_o_per_h.len != layer_count or
        inputs.root_pool_oxygen_uptake_g_o_per_h.len != layer_count)
        return error.LayerConservationActivityDimensionMismatch;
    inline for (inputs.atmosphere_exchange_g_per_h_by_gas_and_layer) |values|
        if (values.len != layer_count) return error.LayerConservationActivityDimensionMismatch;
    inline for (inputs.withdrawal_loss_g_per_h_by_gas_and_layer) |values|
        if (values.len != layer_count) return error.LayerConservationActivityDimensionMismatch;

    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{
        .allocator = ledger.allocator,
        .layout = ledger.layout,
        .activity = candidate_values,
    };
    for (inputs.active_soil_layer_count, 0..) |active_layers, cell| {
        if (active_layers > ledger.layout.soil_layer_capacity)
            return error.LayerConservationActivityDimensionMismatch;
        for (0..ledger.layout.soil_layer_capacity) |local_layer| {
            const flat = cell * ledger.layout.soil_layer_capacity + local_layer;
            const active = local_layer < active_layers;
            const address: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = local_layer };
            inline for (0..root_atmosphere.gas_count) |gas| {
                const atmosphere = inputs.atmosphere_exchange_g_per_h_by_gas_and_layer[gas][flat];
                const withdrawal = inputs.withdrawal_loss_g_per_h_by_gas_and_layer[gas][flat];
                if (!std.math.isFinite(atmosphere) or !std.math.isFinite(withdrawal) or withdrawal > 0)
                    return error.InvalidLayerConservationActivity;
                if (!active and (atmosphere != 0 or withdrawal != 0))
                    return error.InactiveLayerConservationActivity;
                if (atmosphere != 0) try accumulateExternalGain(
                    &candidate,
                    address,
                    active,
                    atmosphere,
                    rootGasTransfer(gas, @abs(atmosphere)),
                );
                if (withdrawal != 0) try accumulateExternalGain(
                    &candidate,
                    address,
                    active,
                    withdrawal,
                    rootGasTransfer(gas, -withdrawal),
                );
            }
            const soil_oxygen = inputs.soil_oxygen_uptake_g_o_per_h[flat];
            const root_oxygen = inputs.root_pool_oxygen_uptake_g_o_per_h[flat];
            if (!std.math.isFinite(soil_oxygen) or soil_oxygen < 0 or
                !std.math.isFinite(root_oxygen) or root_oxygen < 0)
                return error.InvalidLayerConservationActivity;
            if (!active and (soil_oxygen != 0 or root_oxygen != 0))
                return error.InactiveLayerConservationActivity;
            const oxygen_consumption = soil_oxygen + root_oxygen;
            if (!std.math.isFinite(oxygen_consumption))
                return error.InvalidLayerConservationActivity;
            if (oxygen_consumption != 0) try candidate.accumulate(address, .{
                .oxygen_internal_consumption_g = oxygen_consumption,
            });
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Accepted shoot/branch atmospheric activity belongs to the canopy scope;
/// root symbiotic N2 fixation retains EXTRACT's `TUPNF(L)` soil-layer origin.
/// The caller supplies canopy-only cell activity (roots excluded from the
/// cell reducer) so fixation is not duplicated between canopy and root layers.
pub fn accumulatePlantAtmosphereActivity(
    ledger: *Ledger,
    canopy_activity_by_cell: []const hourly.BoundaryActivity,
    active_soil_layer_count: []const usize,
    root_fixation_g_n_per_h_by_layer: []const f64,
) !void {
    if (canopy_activity_by_cell.len != ledger.layout.cell_count or
        active_soil_layer_count.len != ledger.layout.cell_count or
        root_fixation_g_n_per_h_by_layer.len != try ledger.layout.soilCount())
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{
        .allocator = ledger.allocator,
        .layout = ledger.layout,
        .activity = candidate_values,
    };
    for (active_soil_layer_count, 0..) |active_layers, cell| {
        if (active_layers > ledger.layout.soil_layer_capacity)
            return error.LayerConservationActivityDimensionMismatch;
        try candidate.accumulate(.{ .kind = .canopy, .cell = cell }, canopy_activity_by_cell[cell]);
        for (0..ledger.layout.soil_layer_capacity) |local_layer| {
            const flat = cell * ledger.layout.soil_layer_capacity + local_layer;
            const fixation = root_fixation_g_n_per_h_by_layer[flat];
            if (!std.math.isFinite(fixation) or fixation < 0)
                return error.InvalidLayerConservationActivity;
            if (local_layer >= active_layers and fixation != 0)
                return error.InactiveLayerConservationActivity;
            if (fixation != 0) try candidate.accumulate(
                .{ .kind = .soil_layer, .cell = cell, .layer = local_layer },
                .{ .nitrogen_input_g = fixation },
            );
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

fn rootGasTransfer(gas: usize, amount_g: f64) hourly.IntercellTransfer {
    return switch (gas) {
        0, 2 => .{ .carbon_g = amount_g },
        1 => .{ .oxygen_g = amount_g },
        3, 4 => .{ .nitrogen_g = amount_g },
        5 => .{ .hydrogen_g = amount_g },
        else => unreachable,
    };
}

/// Exact accepted WATSUB activity within the snow column. Liquid water and
/// the implicit solute solve move only downward; conduction and vapor
/// diffusion retain their signed interface direction. Interface arrays are
/// indexed by their lower/destination layer, while chemistry is indexed by
/// its upper/source layer exactly as `snow_transport_solver` publishes it.
/// Vapor-equilibrium process heat remains local to its owning snow layer.
pub const SnowTransportActivity = struct {
    active_by_layer: []const bool,
    downward_liquid_water_m3_by_destination: []const f64,
    downward_liquid_heat_megajoules_by_destination: []const f64,
    conduction_heat_megajoules_by_destination: []const f64,
    vapor_water_m3_by_destination: []const f64,
    vapor_heat_megajoules_by_destination: []const f64,
    /// Optional gross direction-separated activity retained by a subcycled
    /// producer. When present, these are authoritative for the local ledger;
    /// the signed arrays above remain the independently accumulated physical
    /// nets and are checked against downward minus upward.
    vapor_water_downward_m3_by_destination: []const f64 = &.{},
    vapor_water_upward_m3_by_destination: []const f64 = &.{},
    vapor_heat_downward_megajoules_by_destination: []const f64 = &.{},
    vapor_heat_upward_megajoules_by_destination: []const f64 = &.{},
    vapor_equilibrium_heat_megajoules_by_layer: []const f64,
    /// Exact signed C*dT from WATSUB's sub-VHCPWX reference assignment.
    inactive_reference_heat_megajoules_by_layer: []const f64,
    accepted_downward_g_by_source_species: []const f64,
    accepted_downward_salt_mol_by_source_species: []const f64,
    dynamic_salts_by_cell: []const bool,
    molar_mass_g_per_mol: inventory.SnowMolarMassesGPerMol,
};

pub fn accumulateSnowTransportActivity(
    ledger: *Ledger,
    inputs: SnowTransportActivity,
) !void {
    @setEvalBranchQuota(10_000);
    const layer_count = try ledger.layout.snowCount();
    const gross_vapor_lengths = .{
        inputs.vapor_water_downward_m3_by_destination.len,
        inputs.vapor_water_upward_m3_by_destination.len,
        inputs.vapor_heat_downward_megajoules_by_destination.len,
        inputs.vapor_heat_upward_megajoules_by_destination.len,
    };
    const has_gross_vapor_activity = gross_vapor_lengths[0] != 0 or
        gross_vapor_lengths[1] != 0 or
        gross_vapor_lengths[2] != 0 or
        gross_vapor_lengths[3] != 0;
    if (inputs.active_by_layer.len != layer_count or
        inputs.downward_liquid_water_m3_by_destination.len != layer_count or
        inputs.downward_liquid_heat_megajoules_by_destination.len != layer_count or
        inputs.conduction_heat_megajoules_by_destination.len != layer_count or
        inputs.vapor_water_m3_by_destination.len != layer_count or
        inputs.vapor_heat_megajoules_by_destination.len != layer_count or
        inputs.vapor_equilibrium_heat_megajoules_by_layer.len != layer_count or
        inputs.inactive_reference_heat_megajoules_by_layer.len != layer_count or
        inputs.accepted_downward_g_by_source_species.len != try std.math.mul(usize, layer_count, snow.species_count) or
        inputs.accepted_downward_salt_mol_by_source_species.len != try std.math.mul(usize, layer_count, snow.salt_species_count) or
        inputs.dynamic_salts_by_cell.len != ledger.layout.cell_count or
        (has_gross_vapor_activity and
            (gross_vapor_lengths[0] != layer_count or
                gross_vapor_lengths[1] != layer_count or
                gross_vapor_lengths[2] != layer_count or
                gross_vapor_lengths[3] != layer_count)))
        return error.LayerConservationActivityDimensionMismatch;
    inline for (.{ inputs.molar_mass_g_per_mol.nitrogen, inputs.molar_mass_g_per_mol.phosphorus }) |value|
        if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidLayerConservationMolarMass;
    inline for (@typeInfo(@TypeOf(inputs.molar_mass_g_per_mol.ions)).@"struct".fields) |field| {
        const value = @field(inputs.molar_mass_g_per_mol.ions, field.name);
        if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidLayerConservationMolarMass;
    }

    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{
        .allocator = ledger.allocator,
        .layout = ledger.layout,
        .activity = candidate_values,
    };
    for (0..ledger.layout.cell_count) |cell| {
        const base = cell * ledger.layout.snow_layer_capacity;
        var inactive_seen = false;
        for (0..ledger.layout.snow_layer_capacity) |local_layer| {
            const layer = base + local_layer;
            const active = inputs.active_by_layer[layer];
            inactive_seen = inactive_seen or !active;
            if (active and inactive_seen) return error.InvalidSnowLayerConservationTopology;

            const process_heat = inputs.vapor_equilibrium_heat_megajoules_by_layer[layer];
            if (!std.math.isFinite(process_heat)) return error.InvalidLayerConservationActivity;
            if (!active and process_heat != 0) return error.InactiveLayerConservationActivity;
            if (process_heat != 0) try candidate.accumulate(
                .{ .kind = .snow_layer, .cell = cell, .layer = local_layer },
                if (process_heat > 0)
                    .{ .heat_internal_production_megajoules = process_heat }
                else
                    .{ .heat_internal_consumption_megajoules = -process_heat },
            );

            const inactive_reference_heat = inputs.inactive_reference_heat_megajoules_by_layer[layer];
            if (!std.math.isFinite(inactive_reference_heat))
                return error.InvalidLayerConservationActivity;
            if (!active and inactive_reference_heat != 0)
                return error.InactiveLayerConservationActivity;
            if (inactive_reference_heat != 0) try candidate.accumulate(
                .{ .kind = .snow_layer, .cell = cell, .layer = local_layer },
                if (inactive_reference_heat > 0)
                    .{ .heat_internal_production_megajoules = inactive_reference_heat }
                else
                    .{ .heat_internal_consumption_megajoules = -inactive_reference_heat },
            );

            const primary_start = layer * snow.species_count;
            const salt_start = layer * snow.salt_species_count;
            const has_lower = local_layer + 1 < ledger.layout.snow_layer_capacity and
                inputs.active_by_layer[layer + 1];
            for (0..snow.species_count) |species_index| {
                const amount_g = inputs.accepted_downward_g_by_source_species[primary_start + species_index];
                if (!std.math.isFinite(amount_g) or amount_g < 0)
                    return error.InvalidLayerConservationActivity;
                if (inputs.dynamic_salts_by_cell[cell] and species_index >= snow.primary_species_count and amount_g != 0)
                    return error.OverlappingSnowLayerConservationSaltActivity;
                if (amount_g != 0) {
                    if (!active or !has_lower) return error.InactiveLayerConservationActivity;
                    try candidate.accumulateTransfer(
                        .{ .kind = .snow_layer, .cell = cell, .layer = local_layer },
                        .{ .kind = .snow_layer, .cell = cell, .layer = local_layer + 1 },
                        try snowPrimaryTransfer(@enumFromInt(species_index), amount_g, inputs.molar_mass_g_per_mol),
                    );
                }
            }
            for (0..snow.salt_species_count) |salt_species_index| {
                const amount_mol = inputs.accepted_downward_salt_mol_by_source_species[salt_start + salt_species_index];
                if (!std.math.isFinite(amount_mol) or amount_mol < 0)
                    return error.InvalidLayerConservationActivity;
                if (!inputs.dynamic_salts_by_cell[cell] and amount_mol != 0)
                    return error.OverlappingSnowLayerConservationSaltActivity;
                if (amount_mol != 0) {
                    if (!active or !has_lower) return error.InactiveLayerConservationActivity;
                    try candidate.accumulateTransfer(
                        .{ .kind = .snow_layer, .cell = cell, .layer = local_layer },
                        .{ .kind = .snow_layer, .cell = cell, .layer = local_layer + 1 },
                        snowSaltTransfer(@enumFromInt(salt_species_index), amount_mol, inputs.molar_mass_g_per_mol.phosphorus),
                    );
                }
            }

            const liquid = inputs.downward_liquid_water_m3_by_destination[layer];
            const liquid_heat = inputs.downward_liquid_heat_megajoules_by_destination[layer];
            const conduction_heat = inputs.conduction_heat_megajoules_by_destination[layer];
            const vapor_water = inputs.vapor_water_m3_by_destination[layer];
            const vapor_heat = inputs.vapor_heat_megajoules_by_destination[layer];
            inline for (.{ liquid, liquid_heat, conduction_heat, vapor_water, vapor_heat }) |value|
                if (!std.math.isFinite(value)) return error.InvalidLayerConservationActivity;
            if (liquid < 0 or liquid_heat < 0 or ((liquid == 0) != (liquid_heat == 0)))
                return error.InvalidLayerConservationActivity;
            var vapor_water_downward = @max(vapor_water, 0);
            var vapor_water_upward = @max(-vapor_water, 0);
            var vapor_heat_downward = @max(vapor_heat, 0);
            var vapor_heat_upward = @max(-vapor_heat, 0);
            if (has_gross_vapor_activity) {
                vapor_water_downward = inputs.vapor_water_downward_m3_by_destination[layer];
                vapor_water_upward = inputs.vapor_water_upward_m3_by_destination[layer];
                vapor_heat_downward = inputs.vapor_heat_downward_megajoules_by_destination[layer];
                vapor_heat_upward = inputs.vapor_heat_upward_megajoules_by_destination[layer];
                inline for (.{
                    vapor_water_downward,
                    vapor_water_upward,
                    vapor_heat_downward,
                    vapor_heat_upward,
                }) |value| if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidLayerConservationActivity;

                const water_activity = vapor_water_downward + vapor_water_upward;
                const heat_activity = vapor_heat_downward + vapor_heat_upward;
                inline for (.{
                    .{ vapor_water, vapor_water_downward - vapor_water_upward, water_activity },
                    .{ vapor_heat, vapor_heat_downward - vapor_heat_upward, heat_activity },
                }) |comparison| {
                    const scale = @max(@abs(comparison[0]), comparison[2]);
                    const tolerance = 256 * std.math.floatEps(f64) * scale;
                    if (!std.math.isFinite(comparison[1]) or
                        @abs(comparison[0] - comparison[1]) > tolerance)
                        return error.SnowVaporGrossActivityMismatch;
                }
            } else if ((vapor_water == 0) != (vapor_heat == 0) or
                (vapor_water > 0 and vapor_heat < 0) or
                (vapor_water < 0 and vapor_heat > 0) or
                (vapor_water != 0 and
                    (!std.math.isFinite(vapor_heat / vapor_water) or vapor_heat / vapor_water <= 0)))
            {
                return error.InvalidLayerConservationVaporHeatPair;
            }
            if (local_layer == 0) {
                if (liquid != 0 or liquid_heat != 0 or conduction_heat != 0 or
                    vapor_water_downward != 0 or vapor_water_upward != 0 or
                    vapor_heat_downward != 0 or vapor_heat_upward != 0)
                    return error.InvalidSnowLayerConservationInterfaceIndex;
                continue;
            }
            const upper_active = inputs.active_by_layer[layer - 1];
            if ((!upper_active or !active) and
                (liquid != 0 or liquid_heat != 0 or conduction_heat != 0 or
                    vapor_water_downward != 0 or vapor_water_upward != 0 or
                    vapor_heat_downward != 0 or vapor_heat_upward != 0))
                return error.InactiveLayerConservationActivity;
            if (liquid != 0) try candidate.accumulateTransfer(
                .{ .kind = .snow_layer, .cell = cell, .layer = local_layer - 1 },
                .{ .kind = .snow_layer, .cell = cell, .layer = local_layer },
                .{ .water_m3 = liquid },
            );
            if (liquid_heat != 0) try candidate.accumulateTransfer(
                .{ .kind = .snow_layer, .cell = cell, .layer = local_layer - 1 },
                .{ .kind = .snow_layer, .cell = cell, .layer = local_layer },
                .{ .heat_megajoules = liquid_heat },
            );
            try accumulateSignedSnowInterface(
                &candidate,
                cell,
                local_layer,
                conduction_heat,
                .{ .heat_megajoules = @abs(conduction_heat) },
            );
            const upper: ScopeAddress = .{ .kind = .snow_layer, .cell = cell, .layer = local_layer - 1 };
            const lower: ScopeAddress = .{ .kind = .snow_layer, .cell = cell, .layer = local_layer };
            if (vapor_water_downward != 0)
                try candidate.accumulateTransfer(upper, lower, .{ .water_m3 = vapor_water_downward });
            if (vapor_water_upward != 0)
                try candidate.accumulateTransfer(lower, upper, .{ .water_m3 = vapor_water_upward });
            if (vapor_heat_downward != 0)
                try candidate.accumulateTransfer(upper, lower, .{ .heat_megajoules = vapor_heat_downward });
            if (vapor_heat_upward != 0)
                try candidate.accumulateTransfer(lower, upper, .{ .heat_megajoules = vapor_heat_upward });
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Exact REDIST relayering activity. Snow layers are fixed local acceptance
/// scopes even though their geometric contents are remapped, so every
/// accepted adjacent transfer must publish donor and recipient activity.
pub const SnowRelayeringActivity = struct {
    active_by_layer: []const bool,
    transfers: *const snow_relayering.AcceptedTransfers,
    dynamic_salts_by_cell: []const bool,
    ice_density_megagrams_per_m3: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    thermodynamics: snow.ThermodynamicParameters,
    molar_mass_g_per_mol: inventory.SnowMolarMassesGPerMol,
};

pub fn accumulateSnowRelayeringActivity(ledger: *Ledger, inputs: SnowRelayeringActivity) !void {
    @setEvalBranchQuota(10_000);
    const layer_count = try ledger.layout.snowCount();
    if (inputs.active_by_layer.len != layer_count or
        inputs.transfers.layer_count != layer_count or
        inputs.transfers.touched_by_layer.len != layer_count or
        inputs.dynamic_salts_by_cell.len != ledger.layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    try validateSnowRelayeringDirection(inputs.transfers.downward, layer_count);
    try validateSnowRelayeringDirection(inputs.transfers.upward, layer_count);
    if (!std.math.isFinite(inputs.ice_density_megagrams_per_m3) or
        inputs.ice_density_megagrams_per_m3 <= 0 or
        inputs.ice_density_megagrams_per_m3 > 1 or
        !std.math.isFinite(inputs.latent_heat_of_fusion_megajoules_per_m3) or
        inputs.latent_heat_of_fusion_megajoules_per_m3 <= 0)
        return error.InvalidLayerConservationThermodynamics;
    inline for (@typeInfo(snow.ThermodynamicParameters).@"struct".fields) |field| {
        const value = @field(inputs.thermodynamics, field.name);
        if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidLayerConservationThermodynamics;
    }
    inline for (.{ inputs.molar_mass_g_per_mol.nitrogen, inputs.molar_mass_g_per_mol.phosphorus }) |value|
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidLayerConservationMolarMass;
    inline for (@typeInfo(@TypeOf(inputs.molar_mass_g_per_mol.ions)).@"struct".fields) |field| {
        const value = @field(inputs.molar_mass_g_per_mol.ions, field.name);
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidLayerConservationMolarMass;
    }
    const ice_heat_capacity_per_water_equivalent_m3_k = try ice_units.heatCapacityPerWaterEquivalentM3K(
        inputs.thermodynamics.ice_heat_capacity_megajoules_per_m3_k,
        inputs.ice_density_megagrams_per_m3,
    );
    const solid_reference_megajoules_per_m3 = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        inputs.thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k,
        inputs.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
        inputs.latent_heat_of_fusion_megajoules_per_m3,
        inputs.thermodynamics.pure_water_melting_temperature_k,
    );
    const ice_reference_megajoules_per_m3 = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        ice_heat_capacity_per_water_equivalent_m3_k,
        inputs.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
        inputs.latent_heat_of_fusion_megajoules_per_m3,
        inputs.thermodynamics.pure_water_melting_temperature_k,
    );

    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (0..ledger.layout.cell_count) |cell| {
        const base = cell * ledger.layout.snow_layer_capacity;
        try requireEmptySnowRelayeringCellTop(inputs.transfers.downward, base);
        try requireEmptySnowRelayeringCellTop(inputs.transfers.upward, base);
        for (1..ledger.layout.snow_layer_capacity) |local_lower| {
            const lower = base + local_lower;
            try accumulateSnowRelayeringDirection(
                &candidate,
                inputs,
                inputs.transfers.downward,
                cell,
                lower,
                local_lower - 1,
                local_lower,
                solid_reference_megajoules_per_m3,
                ice_reference_megajoules_per_m3,
            );
            try accumulateSnowRelayeringDirection(
                &candidate,
                inputs,
                inputs.transfers.upward,
                cell,
                lower,
                local_lower,
                local_lower - 1,
                solid_reference_megajoules_per_m3,
                ice_reference_megajoules_per_m3,
            );
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

fn accumulateSnowRelayeringDirection(
    ledger: *Ledger,
    inputs: SnowRelayeringActivity,
    direction: snow_relayering.Direction,
    cell: usize,
    interface_lower: usize,
    donor_local: usize,
    recipient_local: usize,
    solid_reference_megajoules_per_m3: f64,
    ice_reference_megajoules_per_m3: f64,
) !void {
    const solid = direction.solid_snow_water_equivalent_m3[interface_lower];
    const liquid = direction.liquid_water_m3[interface_lower];
    const vapor = direction.vapor_water_equivalent_m3[interface_lower];
    const ice_volume = direction.ice_volume_m3[interface_lower];
    const sensible_heat = direction.sensible_heat_megajoules[interface_lower];
    inline for (.{ solid, liquid, vapor, ice_volume, sensible_heat }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLayerConservationActivity;
    const ice_water_equivalent = ice_volume * inputs.ice_density_megagrams_per_m3;
    var transfer: hourly.IntercellTransfer = .{
        .water_m3 = solid + liquid + vapor + ice_water_equivalent,
        .heat_megajoules = sensible_heat +
            solid_reference_megajoules_per_m3 * solid +
            ice_reference_megajoules_per_m3 * ice_water_equivalent,
    };
    for (0..snow.species_count) |species_index| {
        const amount = direction.amount_g[interface_lower * snow.species_count + species_index];
        if (!std.math.isFinite(amount) or amount < 0) return error.InvalidLayerConservationActivity;
        if (inputs.dynamic_salts_by_cell[cell] and species_index >= snow.primary_species_count and amount != 0)
            return error.OverlappingSnowLayerConservationSaltActivity;
        transfer = try addIntercellTransfers(
            transfer,
            try snowPrimaryTransfer(@enumFromInt(species_index), amount, inputs.molar_mass_g_per_mol),
        );
    }
    for (0..snow.salt_species_count) |salt_species_index| {
        const amount = direction.salt_amount_mol[interface_lower * snow.salt_species_count + salt_species_index];
        if (!std.math.isFinite(amount) or amount < 0) return error.InvalidLayerConservationActivity;
        if (!inputs.dynamic_salts_by_cell[cell] and amount != 0)
            return error.OverlappingSnowLayerConservationSaltActivity;
        transfer = try addIntercellTransfers(
            transfer,
            snowSaltTransfer(@enumFromInt(salt_species_index), amount, inputs.molar_mass_g_per_mol.phosphorus),
        );
    }
    try validateTransfer(transfer);
    if (std.meta.eql(transfer, hourly.IntercellTransfer{})) return;
    const donor_flat = cell * ledger.layout.snow_layer_capacity + donor_local;
    const recipient_flat = cell * ledger.layout.snow_layer_capacity + recipient_local;
    if (!inputs.active_by_layer[donor_flat] or !inputs.active_by_layer[recipient_flat])
        return error.InactiveLayerConservationActivity;
    try ledger.accumulateTransfer(
        .{ .kind = .snow_layer, .cell = cell, .layer = donor_local },
        .{ .kind = .snow_layer, .cell = cell, .layer = recipient_local },
        transfer,
    );
}

fn validateSnowRelayeringDirection(direction: snow_relayering.Direction, layer_count: usize) !void {
    inline for (.{
        direction.solid_snow_water_equivalent_m3.len,
        direction.liquid_water_m3.len,
        direction.vapor_water_equivalent_m3.len,
        direction.ice_volume_m3.len,
        direction.sensible_heat_megajoules.len,
    }) |length| if (length != layer_count)
        return error.LayerConservationActivityDimensionMismatch;
    if (direction.amount_g.len != try std.math.mul(usize, layer_count, snow.species_count) or
        direction.salt_amount_mol.len != try std.math.mul(usize, layer_count, snow.salt_species_count))
        return error.LayerConservationActivityDimensionMismatch;
}

fn requireEmptySnowRelayeringCellTop(direction: snow_relayering.Direction, top: usize) !void {
    inline for (.{
        direction.solid_snow_water_equivalent_m3[top],
        direction.liquid_water_m3[top],
        direction.vapor_water_equivalent_m3[top],
        direction.ice_volume_m3[top],
        direction.sensible_heat_megajoules[top],
    }) |value| if (value != 0) return error.InvalidLayerConservationFaceTopology;
    for (direction.amount_g[top * snow.species_count ..][0..snow.species_count]) |value|
        if (value != 0) return error.InvalidLayerConservationFaceTopology;
    for (direction.salt_amount_mol[top * snow.salt_species_count ..][0..snow.salt_species_count]) |value|
        if (value != 0) return error.InvalidLayerConservationFaceTopology;
}

// Test-only historical direction oracle. Production deliberately cannot call
// this donor-only shape: atmospheric owners publish through
// `accumulateAcceptedAtmosphericActivity`, while accepted snow discharge must
// use the paired `accumulateSnowSurfaceSoilTransferActivity` transaction.
const SnowExternalDirectionOracle = struct {
    active_by_layer: []const bool,
    atmospheric_solid_water_m3_by_cell: []const f64 = &.{},
    atmospheric_liquid_water_m3_by_cell: []const f64 = &.{},
    atmospheric_heat_megajoules_by_cell: []const f64 = &.{},
    surface_evaporation_m3_by_cell: []const f64 = &.{},
    surface_condensation_m3_by_cell: []const f64 = &.{},
    surface_boundary_heat_megajoules_by_cell: []const f64 = &.{},
    atmospheric_input_g_by_cell_species: []const f64 = &.{},
    atmospheric_input_salt_mol_by_cell_species: []const f64 = &.{},
    discharge_water_m3_by_source_layer: []const f64,
    discharge_heat_megajoules_by_source_layer: []const f64,
    discharge_g_by_source_layer_species: []const f64,
    discharge_salt_mol_by_source_layer_species: []const f64,
    dynamic_salts_by_cell: []const bool,
    molar_mass_g_per_mol: inventory.SnowMolarMassesGPerMol,
};

fn accumulateSnowExternalDirectionOracle(
    ledger: *Ledger,
    inputs: SnowExternalDirectionOracle,
) !void {
    @setEvalBranchQuota(10_000);
    const layer_count = try ledger.layout.snowCount();
    const cell_count = ledger.layout.cell_count;
    const top_external_supplied = inputs.atmospheric_solid_water_m3_by_cell.len != 0;
    inline for (.{
        inputs.atmospheric_solid_water_m3_by_cell.len,
        inputs.atmospheric_liquid_water_m3_by_cell.len,
        inputs.atmospheric_heat_megajoules_by_cell.len,
        inputs.surface_evaporation_m3_by_cell.len,
        inputs.surface_condensation_m3_by_cell.len,
        inputs.surface_boundary_heat_megajoules_by_cell.len,
        inputs.dynamic_salts_by_cell.len,
    }) |length| if (length != (if (top_external_supplied) cell_count else 0)) return error.LayerConservationActivityDimensionMismatch;
    if (inputs.active_by_layer.len != layer_count or
        inputs.atmospheric_input_g_by_cell_species.len != (if (top_external_supplied) try std.math.mul(usize, cell_count, snow.species_count) else 0) or
        inputs.atmospheric_input_salt_mol_by_cell_species.len != (if (top_external_supplied) try std.math.mul(usize, cell_count, snow.salt_species_count) else 0) or
        inputs.discharge_water_m3_by_source_layer.len != layer_count or
        inputs.discharge_heat_megajoules_by_source_layer.len != layer_count or
        inputs.discharge_g_by_source_layer_species.len != try std.math.mul(usize, layer_count, snow.species_count) or
        inputs.discharge_salt_mol_by_source_layer_species.len != try std.math.mul(usize, layer_count, snow.salt_species_count))
        return error.LayerConservationActivityDimensionMismatch;
    inline for (.{ inputs.molar_mass_g_per_mol.nitrogen, inputs.molar_mass_g_per_mol.phosphorus }) |value|
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidLayerConservationMolarMass;
    inline for (@typeInfo(@TypeOf(inputs.molar_mass_g_per_mol.ions)).@"struct".fields) |field| {
        const value = @field(inputs.molar_mass_g_per_mol.ions, field.name);
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidLayerConservationMolarMass;
    }

    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (0..cell_count) |cell| {
        const base = cell * ledger.layout.snow_layer_capacity;
        const top_address: ScopeAddress = .{ .kind = .snow_layer, .cell = cell, .layer = 0 };
        if (top_external_supplied) {
            inline for (.{
                inputs.atmospheric_solid_water_m3_by_cell[cell],
                inputs.atmospheric_liquid_water_m3_by_cell[cell],
                inputs.surface_evaporation_m3_by_cell[cell],
                inputs.surface_condensation_m3_by_cell[cell],
            }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidLayerConservationActivity;
            inline for (.{
                inputs.atmospheric_heat_megajoules_by_cell[cell],
                inputs.surface_boundary_heat_megajoules_by_cell[cell],
            }) |value| if (!std.math.isFinite(value)) return error.InvalidLayerConservationActivity;
            const top_has_activity = inputs.atmospheric_solid_water_m3_by_cell[cell] != 0 or
                inputs.atmospheric_liquid_water_m3_by_cell[cell] != 0 or
                inputs.surface_evaporation_m3_by_cell[cell] != 0 or
                inputs.surface_condensation_m3_by_cell[cell] != 0 or
                inputs.atmospheric_heat_megajoules_by_cell[cell] != 0 or
                inputs.surface_boundary_heat_megajoules_by_cell[cell] != 0;
            if (!inputs.active_by_layer[base] and top_has_activity)
                return error.InactiveLayerConservationActivity;
            try candidate.accumulate(top_address, .{
                .water_input_m3 = inputs.atmospheric_solid_water_m3_by_cell[cell] +
                    inputs.atmospheric_liquid_water_m3_by_cell[cell] +
                    inputs.surface_condensation_m3_by_cell[cell],
                .water_output_m3 = inputs.surface_evaporation_m3_by_cell[cell],
            });
            try accumulateExternalGain(
                &candidate,
                top_address,
                inputs.active_by_layer[base],
                inputs.atmospheric_heat_megajoules_by_cell[cell],
                .{ .heat_megajoules = @abs(inputs.atmospheric_heat_megajoules_by_cell[cell]) },
            );
            try accumulateExternalGain(
                &candidate,
                top_address,
                inputs.active_by_layer[base],
                inputs.surface_boundary_heat_megajoules_by_cell[cell],
                .{ .heat_megajoules = @abs(inputs.surface_boundary_heat_megajoules_by_cell[cell]) },
            );
            for (0..snow.species_count) |species_index| {
                const amount = inputs.atmospheric_input_g_by_cell_species[cell * snow.species_count + species_index];
                if (!std.math.isFinite(amount) or amount < 0) return error.InvalidLayerConservationActivity;
                if (inputs.dynamic_salts_by_cell[cell] and species_index >= snow.primary_species_count and amount != 0)
                    return error.OverlappingSnowLayerConservationSaltActivity;
                if (!inputs.active_by_layer[base] and amount != 0) return error.InactiveLayerConservationActivity;
                if (amount != 0) try candidate.accumulate(
                    top_address,
                    transferActivity(try snowPrimaryTransfer(@enumFromInt(species_index), amount, inputs.molar_mass_g_per_mol), .input),
                );
            }
            for (0..snow.salt_species_count) |salt_species_index| {
                const amount = inputs.atmospheric_input_salt_mol_by_cell_species[cell * snow.salt_species_count + salt_species_index];
                if (!std.math.isFinite(amount) or amount < 0) return error.InvalidLayerConservationActivity;
                if (!inputs.dynamic_salts_by_cell[cell] and amount != 0)
                    return error.OverlappingSnowLayerConservationSaltActivity;
                if (!inputs.active_by_layer[base] and amount != 0) return error.InactiveLayerConservationActivity;
                if (amount != 0) try candidate.accumulate(
                    top_address,
                    transferActivity(snowSaltTransfer(@enumFromInt(salt_species_index), amount, inputs.molar_mass_g_per_mol.phosphorus), .input),
                );
            }
        }

        for (0..ledger.layout.snow_layer_capacity) |local_layer| {
            const layer = base + local_layer;
            const address: ScopeAddress = .{ .kind = .snow_layer, .cell = cell, .layer = local_layer };
            const water = inputs.discharge_water_m3_by_source_layer[layer];
            const heat = inputs.discharge_heat_megajoules_by_source_layer[layer];
            if (!std.math.isFinite(water) or water < 0 or !std.math.isFinite(heat) or heat < 0 or
                ((water == 0) != (heat == 0))) return error.InvalidLayerConservationActivity;
            if (!inputs.active_by_layer[layer] and (water != 0 or heat != 0))
                return error.InactiveLayerConservationActivity;
            if (water != 0) try candidate.accumulate(address, .{ .water_output_m3 = water, .heat_output_megajoules = heat });
            for (0..snow.species_count) |species_index| {
                const amount = inputs.discharge_g_by_source_layer_species[layer * snow.species_count + species_index];
                if (!std.math.isFinite(amount) or amount < 0) return error.InvalidLayerConservationActivity;
                if (inputs.dynamic_salts_by_cell[cell] and species_index >= snow.primary_species_count and amount != 0)
                    return error.OverlappingSnowLayerConservationSaltActivity;
                if (!inputs.active_by_layer[layer] and amount != 0) return error.InactiveLayerConservationActivity;
                if (amount != 0) try candidate.accumulate(
                    address,
                    transferActivity(try snowPrimaryTransfer(@enumFromInt(species_index), amount, inputs.molar_mass_g_per_mol), .output),
                );
            }
            for (0..snow.salt_species_count) |salt_species_index| {
                const amount = inputs.discharge_salt_mol_by_source_layer_species[layer * snow.salt_species_count + salt_species_index];
                if (!std.math.isFinite(amount) or amount < 0) return error.InvalidLayerConservationActivity;
                if (!inputs.dynamic_salts_by_cell[cell] and amount != 0)
                    return error.OverlappingSnowLayerConservationSaltActivity;
                if (!inputs.active_by_layer[layer] and amount != 0) return error.InactiveLayerConservationActivity;
                if (amount != 0) try candidate.accumulate(
                    address,
                    transferActivity(snowSaltTransfer(@enumFromInt(salt_species_index), amount, inputs.molar_mass_g_per_mol.phosphorus), .output),
                );
            }
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// Exact accepted WATSUB/REDIST snow -> litter/topsoil transfer.  Donor
/// amounts retain their acceptance-time snow layer (including warm thin-pack
/// layer zero before drift), while recipients retain the actual physical and
/// chemistry split.  Direct atmospheric inputs are intentionally absent.
pub const SnowSurfaceSoilTransferActivity = struct {
    active_snow_by_layer: []const bool,
    active_soil_layer_count_by_cell: []const usize,
    donor_water_m3_by_snow_layer: []const f64,
    donor_heat_megajoules_by_snow_layer: []const f64,
    donor_g_by_snow_layer_species: []const f64,
    donor_salt_mol_by_snow_layer_species: []const f64,
    surface_water_m3_by_cell: []const f64,
    topsoil_water_m3_by_cell: []const f64,
    surface_heat_megajoules_by_cell: []const f64,
    topsoil_heat_megajoules_by_cell: []const f64,
    accepted_chemistry_by_cell: []const snow.SurfaceDischarge,
    dynamic_salts_by_cell: []const bool,
    molar_mass_g_per_mol: inventory.SnowMolarMassesGPerMol,
};

pub fn accumulateSnowSurfaceSoilTransferActivity(
    ledger: *Ledger,
    inputs: SnowSurfaceSoilTransferActivity,
) !void {
    @setEvalBranchQuota(10_000);
    const snow_count = try ledger.layout.snowCount();
    const cell_count = ledger.layout.cell_count;
    if (inputs.active_snow_by_layer.len != snow_count or
        inputs.active_soil_layer_count_by_cell.len != cell_count or
        inputs.donor_water_m3_by_snow_layer.len != snow_count or
        inputs.donor_heat_megajoules_by_snow_layer.len != snow_count or
        inputs.donor_g_by_snow_layer_species.len != try std.math.mul(usize, snow_count, snow.species_count) or
        inputs.donor_salt_mol_by_snow_layer_species.len != try std.math.mul(usize, snow_count, snow.salt_species_count) or
        inputs.surface_water_m3_by_cell.len != cell_count or
        inputs.topsoil_water_m3_by_cell.len != cell_count or
        inputs.surface_heat_megajoules_by_cell.len != cell_count or
        inputs.topsoil_heat_megajoules_by_cell.len != cell_count or
        inputs.accepted_chemistry_by_cell.len != cell_count or
        inputs.dynamic_salts_by_cell.len != cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    inline for (.{ inputs.molar_mass_g_per_mol.nitrogen, inputs.molar_mass_g_per_mol.phosphorus }) |value|
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidLayerConservationMolarMass;
    inline for (@typeInfo(@TypeOf(inputs.molar_mass_g_per_mol.ions)).@"struct".fields) |field| {
        const value = @field(inputs.molar_mass_g_per_mol.ions, field.name);
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidLayerConservationMolarMass;
    }

    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (0..cell_count) |cell| {
        if (inputs.active_soil_layer_count_by_cell[cell] > ledger.layout.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        const surface_water = inputs.surface_water_m3_by_cell[cell];
        const topsoil_water = inputs.topsoil_water_m3_by_cell[cell];
        const surface_heat = inputs.surface_heat_megajoules_by_cell[cell];
        const topsoil_heat = inputs.topsoil_heat_megajoules_by_cell[cell];
        inline for (.{ surface_water, topsoil_water, surface_heat, topsoil_heat }) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidLayerConservationActivity;
        const discharge = inputs.accepted_chemistry_by_cell[cell];
        var donor_water: f64 = 0;
        var donor_heat: f64 = 0;
        var donor_g: [snow.species_count]f64 = @splat(0);
        var donor_salt: [snow.salt_species_count]f64 = @splat(0);
        const base = cell * ledger.layout.snow_layer_capacity;
        for (0..ledger.layout.snow_layer_capacity) |local_layer| {
            const layer = base + local_layer;
            const water = inputs.donor_water_m3_by_snow_layer[layer];
            const heat = inputs.donor_heat_megajoules_by_snow_layer[layer];
            if (!std.math.isFinite(water) or water < 0 or !std.math.isFinite(heat) or heat < 0 or
                ((water == 0) != (heat == 0))) return error.InvalidLayerConservationActivity;
            if (!inputs.active_snow_by_layer[layer] and (water != 0 or heat != 0))
                return error.InactiveLayerConservationActivity;
            donor_water = try checkedAddFinite(donor_water, water);
            donor_heat = try checkedAddFinite(donor_heat, heat);
            const donor_address: ScopeAddress = .{ .kind = .snow_layer, .cell = cell, .layer = local_layer };
            if (water != 0) try candidate.accumulate(donor_address, .{
                .water_output_m3 = water,
                .heat_output_megajoules = heat,
            });
            for (0..snow.species_count) |species_index| {
                const amount = inputs.donor_g_by_snow_layer_species[layer * snow.species_count + species_index];
                if (!std.math.isFinite(amount) or amount < 0) return error.InvalidLayerConservationActivity;
                if (inputs.dynamic_salts_by_cell[cell] and species_index >= snow.primary_species_count and amount != 0)
                    return error.OverlappingSnowLayerConservationSaltActivity;
                if (!inputs.active_snow_by_layer[layer] and amount != 0)
                    return error.InactiveLayerConservationActivity;
                donor_g[species_index] = try checkedAddFinite(donor_g[species_index], amount);
                if (amount != 0) try candidate.accumulate(
                    donor_address,
                    transferActivity(try snowPrimaryTransfer(@enumFromInt(species_index), amount, inputs.molar_mass_g_per_mol), .output),
                );
            }
            for (0..snow.salt_species_count) |salt_species_index| {
                const amount = inputs.donor_salt_mol_by_snow_layer_species[layer * snow.salt_species_count + salt_species_index];
                if (!std.math.isFinite(amount) or amount < 0) return error.InvalidLayerConservationActivity;
                if (!inputs.dynamic_salts_by_cell[cell] and amount != 0)
                    return error.OverlappingSnowLayerConservationSaltActivity;
                if (!inputs.active_snow_by_layer[layer] and amount != 0)
                    return error.InactiveLayerConservationActivity;
                donor_salt[salt_species_index] = try checkedAddFinite(donor_salt[salt_species_index], amount);
                if (amount != 0) try candidate.accumulate(
                    donor_address,
                    transferActivity(snowSaltTransfer(@enumFromInt(salt_species_index), amount, inputs.molar_mass_g_per_mol.phosphorus), .output),
                );
            }
        }
        try requireSnowTransferRoundoffClosure(donor_water, surface_water + topsoil_water);
        try requireSnowTransferRoundoffClosure(donor_heat, surface_heat + topsoil_heat);
        const has_topsoil_activity = topsoil_water != 0 or topsoil_heat != 0 or
            snowSurfaceDischargeHasSoilActivity(discharge);
        if (inputs.active_soil_layer_count_by_cell[cell] == 0 and has_topsoil_activity)
            return error.InactiveLayerConservationActivity;

        const surface_address: ScopeAddress = .{ .kind = .surface, .cell = cell };
        const soil_address: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = 0 };
        if (surface_water != 0 or surface_heat != 0) try candidate.accumulate(surface_address, .{
            .water_input_m3 = surface_water,
            .heat_input_megajoules = surface_heat,
        });
        if (topsoil_water != 0 or topsoil_heat != 0) try candidate.accumulate(soil_address, .{
            .water_input_m3 = topsoil_water,
            .heat_input_megajoules = topsoil_heat,
        });

        for (0..snow.species_count) |species_index| {
            const litter = discharge.litter_g[species_index];
            const nonband = discharge.soil_nonband_g[species_index];
            const band = discharge.soil_band_g[species_index];
            inline for (.{ litter, nonband, band }) |amount|
                if (!std.math.isFinite(amount) or amount < 0)
                    return error.InvalidLayerConservationActivity;
            if (inputs.dynamic_salts_by_cell[cell] and species_index >= snow.primary_species_count and
                (litter != 0 or nonband != 0 or band != 0))
                return error.OverlappingSnowLayerConservationSaltActivity;
            try requireSnowTransferRoundoffClosure(donor_g[species_index], litter + nonband + band);
            if (litter != 0) try candidate.accumulate(
                surface_address,
                transferActivity(try snowPrimaryTransfer(@enumFromInt(species_index), litter, inputs.molar_mass_g_per_mol), .input),
            );
            const soil_amount = try checkedAddFinite(nonband, band);
            if (soil_amount != 0) try candidate.accumulate(
                soil_address,
                transferActivity(try snowPrimaryTransfer(@enumFromInt(species_index), soil_amount, inputs.molar_mass_g_per_mol), .input),
            );
        }
        for (0..snow.salt_species_count) |salt_species_index| {
            const litter = discharge.litter_salt_mol[salt_species_index];
            const nonband = discharge.soil_nonband_salt_mol[salt_species_index];
            const band = discharge.soil_band_salt_mol[salt_species_index];
            inline for (.{ litter, nonband, band }) |amount|
                if (!std.math.isFinite(amount) or amount < 0)
                    return error.InvalidLayerConservationActivity;
            if (!inputs.dynamic_salts_by_cell[cell] and (litter != 0 or nonband != 0 or band != 0))
                return error.OverlappingSnowLayerConservationSaltActivity;
            try requireSnowTransferRoundoffClosure(donor_salt[salt_species_index], litter + nonband + band);
            if (litter != 0) try candidate.accumulate(
                surface_address,
                transferActivity(snowSaltTransfer(@enumFromInt(salt_species_index), litter, inputs.molar_mass_g_per_mol.phosphorus), .input),
            );
            const soil_amount = try checkedAddFinite(nonband, band);
            if (soil_amount != 0) try candidate.accumulate(
                soil_address,
                transferActivity(snowSaltTransfer(@enumFromInt(salt_species_index), soil_amount, inputs.molar_mass_g_per_mol.phosphorus), .input),
            );
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

/// WATSUB 1786--1796 (`HFLWS1`) and 2025--2033 (`HFLWSRX`) continuous
/// conduction at the base of the snowpack, booked from the donor snow layer
/// that actually formed each face. This is heat only: no water, solute, or gas
/// crosses either face, so it cannot use
/// `accumulateSnowSurfaceSoilTransferActivity`, whose contract pairs
/// nonnegative water with nonnegative heat. Positive values move heat out of
/// the snow layer; negative values move it into the snow layer.
pub fn accumulateSnowBaseConductionActivity(
    ledger: *Ledger,
    active_snow_by_layer: []const bool,
    active_soil_layer_count: []const usize,
    signed_litter_heat_megajoules_by_snow_layer: []const f64,
    signed_topsoil_heat_megajoules_by_snow_layer: []const f64,
) !void {
    const snow_count = try ledger.layout.snowCount();
    if (active_snow_by_layer.len != snow_count or
        active_soil_layer_count.len != ledger.layout.cell_count or
        signed_litter_heat_megajoules_by_snow_layer.len != snow_count or
        signed_topsoil_heat_megajoules_by_snow_layer.len != snow_count)
        return error.LayerConservationActivityDimensionMismatch;

    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{ .allocator = ledger.allocator, .layout = ledger.layout, .activity = candidate_values };
    for (0..ledger.layout.cell_count) |cell| {
        if (active_soil_layer_count[cell] > ledger.layout.soil_layer_capacity)
            return error.InvalidActiveSoilLayerCount;
        const base = cell * ledger.layout.snow_layer_capacity;
        for (0..ledger.layout.snow_layer_capacity) |local_layer| {
            const layer = base + local_layer;
            const litter_heat = signed_litter_heat_megajoules_by_snow_layer[layer];
            const topsoil_heat = signed_topsoil_heat_megajoules_by_snow_layer[layer];
            inline for (.{ litter_heat, topsoil_heat }) |value|
                if (!std.math.isFinite(value)) return error.InvalidLayerConservationActivity;
            if (!active_snow_by_layer[layer] and (litter_heat != 0 or topsoil_heat != 0))
                return error.InactiveLayerConservationActivity;
            if (active_soil_layer_count[cell] == 0 and topsoil_heat != 0)
                return error.InactiveLayerConservationActivity;
            const donor: ScopeAddress = .{ .kind = .snow_layer, .cell = cell, .layer = local_layer };
            if (litter_heat != 0) {
                const surface: ScopeAddress = .{ .kind = .surface, .cell = cell };
                if (litter_heat > 0)
                    try candidate.accumulateTransfer(donor, surface, .{ .heat_megajoules = litter_heat })
                else
                    try candidate.accumulateTransfer(surface, donor, .{ .heat_megajoules = -litter_heat });
            }
            if (topsoil_heat != 0) {
                const topsoil: ScopeAddress = .{ .kind = .soil_layer, .cell = cell, .layer = 0 };
                if (topsoil_heat > 0)
                    try candidate.accumulateTransfer(donor, topsoil, .{ .heat_megajoules = topsoil_heat })
                else
                    try candidate.accumulateTransfer(topsoil, donor, .{ .heat_megajoules = -topsoil_heat });
            }
        }
    }
    @memcpy(ledger.activity, candidate.activity);
}

test "snow base conduction books paired signed heat without any water" {
    var ledger = try Ledger.init(std.testing.allocator, try Layout.init(1, 2, 2));
    defer ledger.deinit();
    // Bottom snow layer is local index 1: warm pack losing heat to litter,
    // cold soil surface returning heat to the pack.
    try accumulateSnowBaseConductionActivity(
        &ledger,
        &.{ true, true },
        &.{2},
        &.{ 0, 3 },
        &.{ 0, -1.25 },
    );
    const donor = ledger.activity[try ledger.layout.index(.{ .kind = .snow_layer, .cell = 0, .layer = 1 })];
    const surface = ledger.activity[try ledger.layout.index(.{ .kind = .surface, .cell = 0 })];
    const topsoil = ledger.activity[try ledger.layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 })];
    try std.testing.expectEqual(@as(f64, 3), donor.heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 1.25), donor.heat_input_megajoules);
    try std.testing.expectEqual(@as(f64, 3), surface.heat_input_megajoules);
    try std.testing.expectEqual(@as(f64, 1.25), topsoil.heat_output_megajoules);
    // Energy only: no carrier may appear on any of the three scopes.
    inline for (.{ donor, surface, topsoil }) |activity| {
        try std.testing.expectEqual(@as(f64, 0), activity.water_input_m3);
        try std.testing.expectEqual(@as(f64, 0), activity.water_output_m3);
    }
    // An untouched interior snow layer must stay empty.
    try std.testing.expect(std.meta.eql(
        ledger.activity[try ledger.layout.index(.{ .kind = .snow_layer, .cell = 0, .layer = 0 })],
        hourly.BoundaryActivity{},
    ));
}

test "snow base conduction rejects inactive donors and absent soil atomically" {
    var ledger = try Ledger.init(std.testing.allocator, try Layout.init(1, 2, 2));
    defer ledger.deinit();
    try std.testing.expectError(error.InactiveLayerConservationActivity, accumulateSnowBaseConductionActivity(
        &ledger,
        &.{ true, false },
        &.{2},
        &.{ 0, 3 },
        &.{ 0, 0 },
    ));
    try std.testing.expectError(error.InactiveLayerConservationActivity, accumulateSnowBaseConductionActivity(
        &ledger,
        &.{ true, true },
        &.{0},
        &.{ 0, 0 },
        &.{ 0, 3 },
    ));
    try std.testing.expectError(error.LayerConservationActivityDimensionMismatch, accumulateSnowBaseConductionActivity(
        &ledger,
        &.{true},
        &.{2},
        &.{ 0, 3 },
        &.{ 0, 0 },
    ));
    for (ledger.activity) |activity|
        try std.testing.expect(std.meta.eql(activity, hourly.BoundaryActivity{}));
}

fn snowSurfaceDischargeHasSoilActivity(discharge: snow.SurfaceDischarge) bool {
    inline for (.{
        discharge.soil_nonband_g[0..],
        discharge.soil_band_g[0..],
        discharge.soil_nonband_salt_mol[0..],
        discharge.soil_band_salt_mol[0..],
    }) |amounts| for (amounts) |amount| if (amount != 0) return true;
    return false;
}

fn requireSnowTransferRoundoffClosure(donor: f64, recipient: f64) !void {
    if (!std.math.isFinite(donor) or !std.math.isFinite(recipient) or donor < 0 or recipient < 0)
        return error.InvalidLayerConservationActivity;
    const scale = @max(1, @max(@abs(donor), @abs(recipient)));
    if (@abs(donor - recipient) > 256 * std.math.floatEps(f64) * scale)
        return error.UnpairedSnowSurfaceSoilTransfer;
}

fn checkedAddFinite(left: f64, right: f64) !f64 {
    const result = left + right;
    if (!std.math.isFinite(result)) return error.InvalidLayerConservationActivity;
    return result;
}

/// Snow drift's producer ledger is already direction-separated and exact;
/// every accepted transfer is owned by snow layer zero at both donor and
/// recipient cells. Preserve that producer activity verbatim rather than
/// reconstructing it from the carrier-only directional diagnostics.
pub fn accumulateCellActivityAtSnowTop(
    ledger: *Ledger,
    active_by_layer: []const bool,
    activity_by_cell: []const hourly.BoundaryActivity,
) !void {
    const snow_count = try ledger.layout.snowCount();
    if (active_by_layer.len != snow_count or
        activity_by_cell.len != ledger.layout.cell_count)
        return error.LayerConservationActivityDimensionMismatch;
    const candidate_values = try ledger.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer ledger.allocator.free(candidate_values);
    var candidate: Ledger = .{
        .allocator = ledger.allocator,
        .layout = ledger.layout,
        .activity = candidate_values,
    };
    for (activity_by_cell, 0..) |activity, cell| {
        const top = cell * ledger.layout.snow_layer_capacity;
        if (!active_by_layer[top] and !std.meta.eql(activity, hourly.BoundaryActivity{}))
            return error.InactiveLayerConservationActivity;
        try candidate.accumulate(.{ .kind = .snow_layer, .cell = cell, .layer = 0 }, activity);
    }
    @memcpy(ledger.activity, candidate.activity);
}

fn accumulateSignedSnowInterface(
    ledger: *Ledger,
    cell: usize,
    lower_layer: usize,
    signed_downward: f64,
    transfer: hourly.IntercellTransfer,
) !void {
    if (signed_downward == 0) return;
    const upper: ScopeAddress = .{ .kind = .snow_layer, .cell = cell, .layer = lower_layer - 1 };
    const lower: ScopeAddress = .{ .kind = .snow_layer, .cell = cell, .layer = lower_layer };
    try ledger.accumulateTransfer(
        if (signed_downward > 0) upper else lower,
        if (signed_downward > 0) lower else upper,
        transfer,
    );
}

fn snowPrimaryTransfer(
    species: snow.Species,
    amount_g: f64,
    molar_mass: inventory.SnowMolarMassesGPerMol,
) !hourly.IntercellTransfer {
    return switch (species) {
        .carbon_dioxide_carbon, .methane_carbon => .{ .carbon_g = amount_g },
        .oxygen => .{ .oxygen_g = amount_g },
        .dinitrogen_nitrogen, .nitrous_oxide_nitrogen, .ammonium_nitrogen, .ammonia_nitrogen, .nitrate_nitrogen => .{ .nitrogen_g = amount_g },
        .hydrogen_phosphate_phosphorus, .dihydrogen_phosphate_phosphorus => .{ .phosphorus_g = amount_g },
        .aluminum => .{ .aluminum_mol = amount_g / molar_mass.ions.aluminum },
        .iron => .{ .iron_mol = amount_g / molar_mass.ions.iron },
        .calcium => .{ .calcium_mol = amount_g / molar_mass.ions.calcium },
        .magnesium => .{ .magnesium_mol = amount_g / molar_mass.ions.magnesium },
        .sodium => .{ .sodium_mol = amount_g / molar_mass.ions.sodium },
        .potassium => .{ .potassium_mol = amount_g / molar_mass.ions.potassium },
        .sulfate_sulfur => .{ .sulfur_mol = amount_g / molar_mass.ions.sulfur },
        .chloride => .{ .chloride_mol = amount_g / molar_mass.ions.chloride },
    };
}

fn snowSaltTransfer(
    species: snow.SaltSpecies,
    amount_mol: f64,
    phosphorus_g_per_mol: f64,
) hourly.IntercellTransfer {
    const formula = surface_aqueous.formula(snow.aqueousSpeciesForSalt(species));
    return .{
        .carbon_g = amount_mol * formula.carbon_mol * 12,
        .phosphorus_g = amount_mol * formula.phosphorus_mol * phosphorus_g_per_mol,
        .aluminum_mol = amount_mol * formula.aluminum_mol,
        .iron_mol = amount_mol * formula.iron_mol,
        .calcium_mol = amount_mol * formula.calcium_mol,
        .magnesium_mol = amount_mol * formula.magnesium_mol,
        .sodium_mol = amount_mol * formula.sodium_mol,
        .potassium_mol = amount_mol * formula.potassium_mol,
        .sulfur_mol = amount_mol * formula.sulfur_mol,
        .chloride_mol = amount_mol * formula.chloride_mol,
        .silicon_mol = amount_mol * formula.silicon_mol,
    };
}

test "runtime snow conservation traversal preserves reflected enum order" {
    inline for (@typeInfo(snow.Species).@"enum".fields, 0..) |field, index| {
        const reflected_species: snow.Species = @enumFromInt(field.value);
        const runtime_species: snow.Species = @enumFromInt(index);
        try std.testing.expectEqual(reflected_species, runtime_species);
    }
    inline for (@typeInfo(snow.SaltSpecies).@"enum".fields, 0..) |field, index| {
        const reflected_species: snow.SaltSpecies = @enumFromInt(field.value);
        const runtime_species: snow.SaltSpecies = @enumFromInt(index);
        try std.testing.expectEqual(reflected_species, runtime_species);
    }
}

fn accumulateExternalGain(
    ledger: *Ledger,
    address: ScopeAddress,
    active: bool,
    signed_gain: f64,
    transfer: hourly.IntercellTransfer,
) !void {
    if (!std.math.isFinite(signed_gain)) return error.InvalidLayerConservationActivity;
    if (signed_gain == 0) return;
    if (!active) return error.InactiveLayerConservationActivity;
    try validateTransfer(transfer);
    try ledger.accumulate(
        address,
        transferActivity(transfer, if (signed_gain > 0) .input else .output),
    );
}

fn accumulateFlatSoilTransfer(
    self: *Ledger,
    first: usize,
    second: usize,
    signed: f64,
    transfer: hourly.IntercellTransfer,
) !void {
    if (!std.math.isFinite(signed) or signed == 0)
        return error.InvalidLayerConservationActivity;
    const donor_flat = if (signed > 0) first else second;
    const recipient_flat = if (signed > 0) second else first;
    const donor = try flatSoilAddress(self.layout, donor_flat);
    const recipient = try flatSoilAddress(self.layout, recipient_flat);
    try self.accumulateTransfer(donor, recipient, transfer);
}

fn flatSoilAddress(layout: Layout, flat: usize) !ScopeAddress {
    if (flat >= try layout.soilCount()) return error.LayerConservationScopeOutOfBounds;
    return .{
        .kind = .soil_layer,
        .cell = flat / layout.soil_layer_capacity,
        .layer = flat % layout.soil_layer_capacity,
    };
}

fn validateSoilFaces(faces: *const hydrology.SoilFaces, layout: Layout) !void {
    const layer_count = try layout.soilCount();
    const count = faces.direction_axis.len;
    inline for (.{
        faces.active_by_face.len,
        faces.micropore_faces.len,
        faces.macropore_faces.len,
        faces.micropore_water_flux_m3_per_step.len,
        faces.macropore_water_flux_m3_per_step.len,
        faces.vapor_flux_m3_per_step.len,
        faces.heat_flux_megajoules_per_step.len,
    }) |length| if (length != count)
        return error.LayerConservationActivityDimensionMismatch;
    if (faces.active_by_layer.len != layer_count)
        return error.LayerConservationActivityDimensionMismatch;
    for (0..count) |face| {
        const micro = faces.micropore_faces[face];
        const macro = faces.macropore_faces[face];
        const axis = faces.direction_axis[face];
        if (axis > 2 or micro.first_cell >= layer_count or micro.second_cell >= layer_count or
            micro.first_cell == micro.second_cell or micro.first_cell != macro.first_cell or
            micro.second_cell != macro.second_cell)
            return error.InvalidLayerConservationFaceTopology;
        if (axis == 2) {
            // A promoted DLYRM vertical face may skip thin layers, so require
            // same column and increasing local depth, not adjacency.
            if (micro.first_cell / layout.soil_layer_capacity !=
                micro.second_cell / layout.soil_layer_capacity or
                micro.first_cell % layout.soil_layer_capacity >=
                    micro.second_cell % layout.soil_layer_capacity)
                return error.InvalidLayerConservationFaceTopology;
        } else if (micro.first_cell / layout.soil_layer_capacity ==
            micro.second_cell / layout.soil_layer_capacity)
        {
            return error.InvalidLayerConservationFaceTopology;
        }
        if (faces.active_by_face[face] and
            (!faces.active_by_layer[micro.first_cell] or
                !faces.active_by_layer[micro.second_cell]))
            return error.InvalidLayerConservationFaceTopology;
    }
}

pub fn evaluate(
    allocator: std.mem.Allocator,
    storage_before: []const inventory.Storage,
    storage_after: []const inventory.Storage,
    activity: []const hourly.BoundaryActivity,
    scope_area_m2: []const f64,
    tolerances: hourly.Tolerances,
) !hourly.Report {
    return hourly.evaluateForScope(
        allocator,
        storage_before,
        storage_after,
        activity,
        scope_area_m2,
        tolerances,
        .hourly,
    );
}

pub fn requireAccepted(report: hourly.Report) !void {
    if (!report.accepted()) return error.HourlyLayerConservationFailure;
}

test "accepted terminal recovery producer commits explain exact deep-layer closure and reject leakage" {
    const layout = try Layout.init(1, 1, 1);
    var layer_ledger = try Ledger.init(std.testing.allocator, layout);
    defer layer_ledger.deinit();
    var cell_ledger = try hourly.BoundaryLedger.init(std.testing.allocator, 1);
    defer cell_ledger.deinit();

    const before_water = 2.5563198907705675e-1;
    const after_water = 2.556319469646039e-1;
    const input_water = 1.676830523392181e-10;
    const output_water = 4.228012845386431e-8;
    var before: [4]inventory.Storage = @splat(.{});
    var after: [4]inventory.Storage = @splat(.{});
    before[0].water_m3 = before_water;
    after[0].water_m3 = after_water;
    layer_ledger.activity[0] = .{
        .water_input_m3 = input_water,
        .water_output_m3 = output_water,
    };
    cell_ledger.cells[0] = layer_ledger.activity[0];
    // The accepted local water gates certify this a-priori producer bound.
    // It is not derived from the observed hourly closure residual.
    layer_ledger.pending_water_storage_roundoff_allowance_m3_by_scope[0] =
        1.453099864220819e-14;

    try accumulateAcceptedWaterStorageUpdateRoundoff(
        &cell_ledger,
        &layer_ledger,
        &before,
        &after,
    );
    const expected_residual = -7.456708861486305e-15;
    const provenance = layer_ledger.activity[0]
        .water_storage_update_roundoff_allowance_m3;
    try std.testing.expectApproxEqRel(
        @as(f64, 1.453099864220819e-14),
        provenance,
        8 * std.math.floatEps(f64),
    );
    try std.testing.expectEqual(provenance, cell_ledger.cells[0]
        .water_storage_update_roundoff_allowance_m3);
    try std.testing.expectEqualSlices(
        u16,
        &.{ 0, 0, 0, 0 },
        layer_ledger.water_storage_update_operation_count_by_scope,
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 0, 0, 0, 0 },
        layer_ledger.pending_water_storage_roundoff_allowance_m3_by_scope,
    );

    const tolerances: hourly.Tolerances = .{
        .absolute_per_area = .{ .water_m = 0 },
        .relative = 1.0e-9,
    };
    var layer_report = try evaluate(
        std.testing.allocator,
        &before,
        &after,
        layer_ledger.activity,
        &.{ 1, 1, 1, 1 },
        tolerances,
    );
    defer layer_report.deinit(std.testing.allocator);
    const water_index: usize = @intFromEnum(hourly.Quantity.water);
    const closure = layer_report.cells[0].closure[water_index];
    try std.testing.expectEqual(expected_residual, closure.residual);
    try std.testing.expect(!closure.physical_accepted);
    try std.testing.expect(closure.accepted);
    try std.testing.expectEqual(@as(f64, 4.244781150620353e-17), closure.acceptance_limit);

    var accumulated_state: ?AccumulatedState = null;
    defer if (accumulated_state) |*state| state.deinit();
    var accumulated_report = try evaluateAndCommitAccumulated(
        &accumulated_state,
        std.testing.allocator,
        std.testing.allocator,
        layout,
        &before,
        &after,
        layer_ledger.activity,
        &.{ 1, 1, 1, 1 },
        tolerances,
        0,
    );
    defer accumulated_report.deinit(std.testing.allocator);
    try std.testing.expect(accumulated_report.accepted());
    try std.testing.expectEqual(
        provenance,
        accumulated_state.?.cumulative_activity[0]
            .water_storage_update_roundoff_allowance_m3,
    );

    var leaked_after = after;
    leaked_after[0].water_m3 -= 1.0e-12;
    var leaked_report = try evaluate(
        std.testing.allocator,
        &before,
        &leaked_after,
        layer_ledger.activity,
        &.{ 1, 1, 1, 1 },
        tolerances,
    );
    defer leaked_report.deinit(std.testing.allocator);
    try std.testing.expect(!leaked_report.cells[0].closure[water_index].accepted);

    // A single producer publication receives no added forward-sequence bound;
    // its existing final-identity bound remains the sole arithmetic gate.
    var one_step_layer = try Ledger.init(std.testing.allocator, layout);
    defer one_step_layer.deinit();
    var one_step_cell = try hourly.BoundaryLedger.init(std.testing.allocator, 1);
    defer one_step_cell.deinit();
    one_step_layer.activity[0] = .{
        .water_input_m3 = input_water,
        .water_output_m3 = output_water,
    };
    one_step_cell.cells[0] = one_step_layer.activity[0];
    one_step_layer.water_storage_update_operation_count_by_scope[0] = 1;
    try accumulateAcceptedWaterStorageUpdateRoundoff(
        &one_step_cell,
        &one_step_layer,
        &before,
        &after,
    );
    try std.testing.expectEqual(@as(f64, 0), one_step_layer.activity[0]
        .water_storage_update_roundoff_allowance_m3);
    var one_step_report = try evaluate(
        std.testing.allocator,
        &before,
        &after,
        one_step_layer.activity,
        &.{ 1, 1, 1, 1 },
        tolerances,
    );
    defer one_step_report.deinit(std.testing.allocator);
    try std.testing.expect(!one_step_report.cells[0].closure[water_index].accepted);
}

test "spatial heat provenance remains local and cannot admit historical phase defect" {
    const layout = try Layout.init(1, 1, 1);
    var layer_ledger = try Ledger.init(std.testing.allocator, layout);
    defer layer_ledger.deinit();
    var cell_ledger = try hourly.BoundaryLedger.init(std.testing.allocator, 1);
    defer cell_ledger.deinit();
    var before: [4]inventory.Storage = @splat(.{});
    var after = before;
    before[0].heat_megajoules = 1.895781103957807e3;
    after[0].heat_megajoules = 1.894738980835847e3;
    layer_ledger.activity[0] = .{
        .heat_input_megajoules = 4.104975761801748e-2,
        .heat_output_megajoules = 3.4800297335465685e-1,
        .heat_internal_production_megajoules = 1.2476578771252779e-2,
        .heat_internal_consumption_megajoules = 7.476464834975015e-1,
    };
    cell_ledger.cells[0] = layer_ledger.activity[0];
    // Two 32-operation canonical enthalpy censuses at the logged standing
    // magnitude contribute about 2.7e-11 MJ. This source-derived scale is
    // intentionally far below the removed 4096*eps certificate.
    layer_ledger.pending_heat_storage_roundoff_allowance_megajoules_by_scope[0] =
        2.7e-11;
    try accumulateAcceptedHeatStorageUpdateRoundoff(&cell_ledger, &layer_ledger);
    try std.testing.expectEqual(
        @as(f64, 2.7e-11),
        layer_ledger.activity[0].heat_storage_update_roundoff_allowance_megajoules,
    );
    try std.testing.expectEqual(
        layer_ledger.activity[0].heat_storage_update_roundoff_allowance_megajoules,
        cell_ledger.cells[0].heat_storage_update_roundoff_allowance_megajoules,
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 0, 0, 0, 0 },
        layer_ledger.pending_heat_storage_roundoff_allowance_megajoules_by_scope,
    );
    const tolerances: hourly.Tolerances = .{
        .absolute_per_area = .{},
        .relative = 1.0e-9,
    };
    var report = try evaluate(
        std.testing.allocator,
        &before,
        &after,
        layer_ledger.activity,
        &.{ 1, 1, 1, 1 },
        tolerances,
    );
    defer report.deinit(std.testing.allocator);
    const heat_index: usize = @intFromEnum(hourly.Quantity.heat);
    try std.testing.expect(!report.cells[0].closure[heat_index].physical_accepted);
    try std.testing.expect(!report.cells[0].closure[heat_index].accepted);

    var leaked_after = after;
    leaked_after[0].heat_megajoules -= 1.0e-6;
    var leaked = try evaluate(
        std.testing.allocator,
        &before,
        &leaked_after,
        layer_ledger.activity,
        &.{ 1, 1, 1, 1 },
        tolerances,
    );
    defer leaked.deinit(std.testing.allocator);
    try std.testing.expect(!leaked.cells[0].closure[heat_index].accepted);
}

test "per-scope water update provenance remains local and is consumed once" {
    const layout = try Layout.init(1, 1, 1);
    var layer_ledger = try Ledger.init(std.testing.allocator, layout);
    defer layer_ledger.deinit();
    var cell_ledger = try hourly.BoundaryLedger.init(std.testing.allocator, 1);
    defer cell_ledger.deinit();

    var before: [4]inventory.Storage = @splat(.{});
    var after = before;
    before[0].water_m3 = 0.25;
    after[0].water_m3 = 0.25;
    before[1].water_m3 = 0.125;
    after[1].water_m3 = 0.125;
    before[2].water_m3 = 0.0625;
    after[2].water_m3 = 0.0625;
    layer_ledger.water_storage_update_operation_count_by_scope[0] = 4;
    layer_ledger.water_storage_update_operation_count_by_scope[1] = 2;
    layer_ledger.water_storage_update_operation_count_by_scope[2] = 3;
    layer_ledger.pending_water_storage_roundoff_allowance_m3_by_scope[0] = 1.0e-14;

    try accumulateAcceptedWaterStorageUpdateRoundoff(
        &cell_ledger,
        &layer_ledger,
        &before,
        &after,
    );
    const soil = layer_ledger.activity[0].water_storage_update_roundoff_allowance_m3;
    const snow_allowance = layer_ledger.activity[1].water_storage_update_roundoff_allowance_m3;
    const surface = layer_ledger.activity[2].water_storage_update_roundoff_allowance_m3;
    try std.testing.expect(soil > snow_allowance and snow_allowance > surface and surface > 0);
    const first_sum = std.math.nextAfter(f64, soil + snow_allowance, std.math.inf(f64));
    const expected_cell = std.math.nextAfter(f64, first_sum + surface, std.math.inf(f64));
    try std.testing.expectEqual(expected_cell, cell_ledger.cells[0].water_storage_update_roundoff_allowance_m3);
    try std.testing.expectEqualSlices(
        u16,
        &.{ 0, 0, 0, 0 },
        layer_ledger.water_storage_update_operation_count_by_scope,
    );
    try std.testing.expectEqualSlices(
        f64,
        &.{ 0, 0, 0, 0 },
        layer_ledger.pending_water_storage_roundoff_allowance_m3_by_scope,
    );
    try std.testing.expectError(
        error.DuplicateWaterStorageUpdateArithmeticProvenance,
        accumulateAcceptedWaterStorageUpdateRoundoff(
            &cell_ledger,
            &layer_ledger,
            &before,
            &after,
        ),
    );
}

test "pending water producer provenance is local and invalid canopy publication is atomic" {
    const layout = try Layout.init(1, 1, 1);
    var layer_ledger = try Ledger.init(std.testing.allocator, layout);
    defer layer_ledger.deinit();
    var cell_ledger = try hourly.BoundaryLedger.init(std.testing.allocator, 1);
    defer cell_ledger.deinit();
    const before: [4]inventory.Storage = @splat(.{});
    const after = before;

    layer_ledger.pending_water_storage_roundoff_allowance_m3_by_scope[0] = 2.0e-14;
    layer_ledger.pending_water_storage_roundoff_allowance_m3_by_scope[3] = 1.0e-14;
    var pending_before: [4]f64 = undefined;
    @memcpy(&pending_before, layer_ledger.pending_water_storage_roundoff_allowance_m3_by_scope);
    try std.testing.expectError(
        error.InvalidWaterStorageUpdateArithmeticProvenance,
        accumulateAcceptedWaterStorageUpdateRoundoff(
            &cell_ledger,
            &layer_ledger,
            &before,
            &after,
        ),
    );
    try std.testing.expectEqualSlices(
        f64,
        pending_before[0..],
        layer_ledger.pending_water_storage_roundoff_allowance_m3_by_scope,
    );
    for (layer_ledger.activity) |activity|
        try std.testing.expectEqual(@as(f64, 0), activity.water_storage_update_roundoff_allowance_m3);
    try std.testing.expectEqual(@as(f64, 0), cell_ledger.cells[0].water_storage_update_roundoff_allowance_m3);

    layer_ledger.pending_water_storage_roundoff_allowance_m3_by_scope[3] = 0;
    try accumulateAcceptedWaterStorageUpdateRoundoff(
        &cell_ledger,
        &layer_ledger,
        &before,
        &after,
    );
    try std.testing.expectEqual(@as(f64, 2.0e-14), layer_ledger.activity[0].water_storage_update_roundoff_allowance_m3);
    try std.testing.expectEqual(@as(f64, 2.0e-14), cell_ledger.cells[0].water_storage_update_roundoff_allowance_m3);
}

test "chemistry rebase provenance maps exact layers and reduces atomically by cell" {
    const layout = try Layout.init(2, 2, 1);
    var layer_ledger = try Ledger.init(std.testing.allocator, layout);
    defer layer_ledger.deinit();
    var cell_ledger = try hourly.BoundaryLedger.init(std.testing.allocator, 2);
    defer cell_ledger.deinit();
    const allowances = [_]chemistry_water_rebase.RoundoffAllowance{
        .{ .carbon_mol = 1, .phosphorus_mol = 2, .calcium_mol = 3, .magnesium_mol = 4, .silicon_mol = 5 },
        .{ .phosphorus_mol = 6, .iron_mol = 7, .sodium_mol = 8, .sulfur_mol = 9 },
        .{ .phosphorus_mol = 10, .calcium_mol = 11, .potassium_mol = 12, .silicon_mol = 13 },
        .{ .carbon_mol = 14, .aluminum_mol = 15, .iron_mol = 16, .magnesium_mol = 17 },
    };
    try accumulateAcceptedChemistryRebaseRoundoff(
        &cell_ledger,
        &layer_ledger,
        &allowances,
        12,
        31,
    );

    try std.testing.expect(layer_ledger.activity[0].carbon_storage_update_roundoff_allowance_g > 12);
    try std.testing.expect(layer_ledger.activity[0].phosphorus_storage_update_roundoff_allowance_g > 62);
    try std.testing.expectEqual(@as(f64, 3), layer_ledger.activity[0].calcium_storage_update_roundoff_allowance_mol);
    try std.testing.expectEqual(@as(f64, 4), layer_ledger.activity[0].magnesium_storage_update_roundoff_allowance_mol);
    try std.testing.expectEqual(@as(f64, 5), layer_ledger.activity[0].silicon_storage_update_roundoff_allowance_mol);
    try std.testing.expect(layer_ledger.activity[1].phosphorus_storage_update_roundoff_allowance_g > 186);
    try std.testing.expectEqual(@as(f64, 7), layer_ledger.activity[1].iron_storage_update_roundoff_allowance_mol);
    try std.testing.expectEqual(@as(f64, 8), layer_ledger.activity[1].sodium_storage_update_roundoff_allowance_mol);
    try std.testing.expectEqual(@as(f64, 9), layer_ledger.activity[1].sulfur_storage_update_roundoff_allowance_mol);
    try std.testing.expect(layer_ledger.activity[2].phosphorus_storage_update_roundoff_allowance_g > 310);
    try std.testing.expectEqual(@as(f64, 11), layer_ledger.activity[2].calcium_storage_update_roundoff_allowance_mol);
    try std.testing.expectEqual(@as(f64, 12), layer_ledger.activity[2].potassium_storage_update_roundoff_allowance_mol);
    try std.testing.expectEqual(@as(f64, 13), layer_ledger.activity[2].silicon_storage_update_roundoff_allowance_mol);
    try std.testing.expect(layer_ledger.activity[3].carbon_storage_update_roundoff_allowance_g > 168);
    try std.testing.expectEqual(@as(f64, 15), layer_ledger.activity[3].aluminum_storage_update_roundoff_allowance_mol);
    try std.testing.expectEqual(@as(f64, 16), layer_ledger.activity[3].iron_storage_update_roundoff_allowance_mol);
    try std.testing.expectEqual(@as(f64, 17), layer_ledger.activity[3].magnesium_storage_update_roundoff_allowance_mol);
    try std.testing.expect(cell_ledger.cells[0].phosphorus_storage_update_roundoff_allowance_g > 248);
    try std.testing.expect(cell_ledger.cells[1].carbon_storage_update_roundoff_allowance_g > 168);
    try std.testing.expectEqual(
        layer_ledger.activity[3].iron_storage_update_roundoff_allowance_mol,
        cell_ledger.cells[1].iron_storage_update_roundoff_allowance_mol,
    );

    var fresh_layer = try Ledger.init(std.testing.allocator, layout);
    defer fresh_layer.deinit();
    var fresh_cell = try hourly.BoundaryLedger.init(std.testing.allocator, 2);
    defer fresh_cell.deinit();
    var invalid = allowances;
    invalid[3].phosphorus_mol = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidSoilChemistryWaterCarrierRoundoff,
        accumulateAcceptedChemistryRebaseRoundoff(
            &fresh_cell,
            &fresh_layer,
            &invalid,
            12,
            31,
        ),
    );
    for (fresh_layer.activity) |activity|
        try std.testing.expectEqualDeep(hourly.BoundaryActivity{}, activity);
    for (fresh_cell.cells) |activity|
        try std.testing.expectEqualDeep(hourly.BoundaryActivity{}, activity);
}

test "surface chemistry rebase provenance maps only surface and owning cell" {
    const layout = try Layout.init(2, 2, 1);
    var layer_ledger = try Ledger.init(std.testing.allocator, layout);
    defer layer_ledger.deinit();
    var cell_ledger = try hourly.BoundaryLedger.init(std.testing.allocator, 2);
    defer cell_ledger.deinit();
    const allowances = [_]chemistry_water_rebase.RoundoffAllowance{
        .{
            .carbon_g = 121,
            .nitrogen_g = 57,
            .phosphorus_g = 125,
            .carbon_mol = 1,
            .nitrogen_mol = 2,
            .phosphorus_mol = 3,
            .aluminum_mol = 4,
            .chloride_mol = 5,
        },
        .{ .iron_mol = 6, .calcium_mol = 7, .sulfur_mol = 8 },
    };
    try accumulateAcceptedSurfaceChemistryRebaseRoundoff(
        &cell_ledger,
        &layer_ledger,
        &allowances,
        12,
        14,
        31,
    );

    const first_surface = try layout.index(.{ .kind = .surface, .cell = 0 });
    const second_surface = try layout.index(.{ .kind = .surface, .cell = 1 });
    try std.testing.expectEqual(@as(f64, 121), layer_ledger.activity[first_surface].carbon_storage_update_roundoff_allowance_g);
    try std.testing.expectEqual(@as(f64, 57), layer_ledger.activity[first_surface].nitrogen_storage_update_roundoff_allowance_g);
    try std.testing.expectEqual(@as(f64, 125), layer_ledger.activity[first_surface].phosphorus_storage_update_roundoff_allowance_g);
    try std.testing.expectEqual(@as(f64, 4), layer_ledger.activity[first_surface].aluminum_storage_update_roundoff_allowance_mol);
    try std.testing.expectEqual(@as(f64, 5), layer_ledger.activity[first_surface].chloride_storage_update_roundoff_allowance_mol);
    try std.testing.expectEqual(@as(f64, 6), layer_ledger.activity[second_surface].iron_storage_update_roundoff_allowance_mol);
    try std.testing.expectEqualDeep(
        layer_ledger.activity[first_surface],
        cell_ledger.cells[0],
    );
    try std.testing.expectEqualDeep(
        layer_ledger.activity[second_surface],
        cell_ledger.cells[1],
    );
    for (0..layout.soil_layer_capacity) |layer| {
        try std.testing.expectEqualDeep(
            hourly.BoundaryActivity{},
            layer_ledger.activity[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = layer })],
        );
    }

    var invalid = allowances;
    invalid[1].chloride_mol = std.math.nan(f64);
    var fresh_layer = try Ledger.init(std.testing.allocator, layout);
    defer fresh_layer.deinit();
    var fresh_cell = try hourly.BoundaryLedger.init(std.testing.allocator, 2);
    defer fresh_cell.deinit();
    try std.testing.expectError(
        error.InvalidSoilChemistryWaterCarrierRoundoff,
        accumulateAcceptedSurfaceChemistryRebaseRoundoff(
            &fresh_cell,
            &fresh_layer,
            &invalid,
            12,
            14,
            31,
        ),
    );
    for (fresh_layer.activity) |activity|
        try std.testing.expectEqualDeep(hourly.BoundaryActivity{}, activity);
    for (fresh_cell.cells) |activity|
        try std.testing.expectEqualDeep(hourly.BoundaryActivity{}, activity);
}

/// Restart-persisted, independently reconstructible local-scope history.
/// Baseline/latest storage and direction-separated throughput are retained;
/// there is no column or domain reduction and no accounting reset can erase a
/// same-sign leak that is individually below the hourly absolute tolerance.
pub const AccumulatedState = struct {
    allocator: std.mem.Allocator,
    layout: Layout,
    baseline_storage: []inventory.Storage,
    latest_storage: []inventory.Storage,
    cumulative_activity: []hourly.BoundaryActivity,
    accepted_hour_count: u64,

    pub fn initEmpty(allocator: std.mem.Allocator, layout: Layout) !AccumulatedState {
        const scope_count = try layout.scopeCount();
        const baseline = try allocator.alloc(inventory.Storage, scope_count);
        errdefer allocator.free(baseline);
        const latest = try allocator.alloc(inventory.Storage, scope_count);
        errdefer allocator.free(latest);
        const activity = try allocator.alloc(hourly.BoundaryActivity, scope_count);
        errdefer allocator.free(activity);
        @memset(baseline, .{});
        @memset(latest, .{});
        @memset(activity, .{});
        return .{
            .allocator = allocator,
            .layout = layout,
            .baseline_storage = baseline,
            .latest_storage = latest,
            .cumulative_activity = activity,
            .accepted_hour_count = 0,
        };
    }

    pub fn deinit(self: *AccumulatedState) void {
        self.allocator.free(self.cumulative_activity);
        self.allocator.free(self.latest_storage);
        self.allocator.free(self.baseline_storage);
        self.* = undefined;
    }

    pub fn clone(self: AccumulatedState, allocator: std.mem.Allocator) !AccumulatedState {
        try self.validate();
        var result = try initEmpty(allocator, self.layout);
        errdefer result.deinit();
        @memcpy(result.baseline_storage, self.baseline_storage);
        @memcpy(result.latest_storage, self.latest_storage);
        @memcpy(result.cumulative_activity, self.cumulative_activity);
        result.accepted_hour_count = self.accepted_hour_count;
        return result;
    }

    pub fn validate(self: AccumulatedState) !void {
        const scope_count = try self.layout.scopeCount();
        if (self.accepted_hour_count == 0 or
            self.baseline_storage.len != scope_count or
            self.latest_storage.len != scope_count or
            self.cumulative_activity.len != scope_count)
            return error.InvalidAccumulatedLayerConservationState;
        for (self.baseline_storage, self.latest_storage, self.cumulative_activity) |baseline, latest, activity| {
            try baseline.validate();
            try latest.validate();
            // `addActivities` performs the same validation without exposing
            // the cell module's private validator.
            _ = try hourly.addActivities(activity, .{});
        }
    }
};

/// Preview, locally gate, then atomically commit one fixed external hour.
/// `slot` is unchanged on continuity or accumulated-closure failure, so the
/// outer-hour retry/rollback path has zero diagnostic side effects.
pub fn evaluateAndCommitAccumulated(
    slot: *?AccumulatedState,
    owner_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    layout: Layout,
    storage_before: []const inventory.Storage,
    storage_after: []const inventory.Storage,
    hourly_activity: []const hourly.BoundaryActivity,
    scope_area_m2: []const f64,
    tolerances: hourly.Tolerances,
    expected_previous_hour_count: u64,
) !hourly.Report {
    const scope_count = try layout.scopeCount();
    if (storage_before.len != scope_count or storage_after.len != scope_count or
        hourly_activity.len != scope_count or scope_area_m2.len != scope_count)
        return error.AccumulatedLayerConservationDimensionMismatch;

    if (slot.*) |*live| {
        try live.validate();
        if (!std.meta.eql(live.layout, layout) or
            live.accepted_hour_count != expected_previous_hour_count)
            return error.AccumulatedLayerConservationHistoryMismatch;
        const next_hour_count = std.math.add(u64, live.accepted_hour_count, 1) catch
            return error.AccumulatedLayerConservationHistoryOverflow;
        const candidate_activity = try scratch_allocator.alloc(hourly.BoundaryActivity, scope_count);
        defer scratch_allocator.free(candidate_activity);
        @memset(candidate_activity, .{});
        var continuity = try hourly.evaluateForScope(
            scratch_allocator,
            live.latest_storage,
            storage_before,
            candidate_activity,
            scope_area_m2,
            tolerances,
            .accumulated_continuity,
        );
        defer continuity.deinit(scratch_allocator);
        if (!continuity.accepted())
            return error.AccumulatedLayerStorageDiscontinuity;
        for (candidate_activity, live.cumulative_activity, hourly_activity) |*candidate, accumulated, current|
            candidate.* = try hourly.addActivities(accumulated, current);
        var report = try hourly.evaluateForScope(
            scratch_allocator,
            live.baseline_storage,
            storage_after,
            candidate_activity,
            scope_area_m2,
            tolerances,
            .accumulated,
        );
        if (!report.accepted()) {
            report.deinit(scratch_allocator);
            return error.AccumulatedLayerConservationFailure;
        }
        @memcpy(live.latest_storage, storage_after);
        @memcpy(live.cumulative_activity, candidate_activity);
        live.accepted_hour_count = next_hour_count;
        return report;
    }

    if (expected_previous_hour_count != 0)
        return error.AccumulatedLayerConservationHistoryMismatch;
    var candidate = try AccumulatedState.initEmpty(owner_allocator, layout);
    errdefer candidate.deinit();
    @memcpy(candidate.baseline_storage, storage_before);
    @memcpy(candidate.latest_storage, storage_after);
    for (candidate.cumulative_activity, hourly_activity) |*destination, source|
        destination.* = try hourly.addActivities(.{}, source);
    candidate.accepted_hour_count = 1;
    var report = try hourly.evaluateForScope(
        scratch_allocator,
        candidate.baseline_storage,
        candidate.latest_storage,
        candidate.cumulative_activity,
        scope_area_m2,
        tolerances,
        .accumulated,
    );
    if (!report.accepted()) {
        report.deinit(scratch_allocator);
        return error.AccumulatedLayerConservationFailure;
    }
    slot.* = candidate;
    return report;
}

fn validateTransfer(transfer: hourly.IntercellTransfer) !void {
    inline for (std.meta.fields(hourly.IntercellTransfer)) |field| {
        const value = @field(transfer, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLayerConservationTransfer;
    }
}

fn addIntercellTransfers(
    left: hourly.IntercellTransfer,
    right: hourly.IntercellTransfer,
) !hourly.IntercellTransfer {
    var result: hourly.IntercellTransfer = .{};
    inline for (std.meta.fields(hourly.IntercellTransfer)) |field| {
        const value = @field(left, field.name) + @field(right, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLayerConservationTransfer;
        @field(result, field.name) = value;
    }
    return result;
}

fn transferActivity(
    transfer: hourly.IntercellTransfer,
    direction: enum { input, output },
) hourly.BoundaryActivity {
    return switch (direction) {
        .input => .{
            .water_input_m3 = transfer.water_m3,
            .heat_input_megajoules = transfer.heat_megajoules,
            .oxygen_input_g = transfer.oxygen_g,
            .hydrogen_input_g = transfer.hydrogen_g,
            .carbon_input_g = transfer.carbon_g,
            .nitrogen_input_g = transfer.nitrogen_g,
            .phosphorus_input_g = transfer.phosphorus_g,
            .aluminum_input_mol = transfer.aluminum_mol,
            .iron_input_mol = transfer.iron_mol,
            .calcium_input_mol = transfer.calcium_mol,
            .magnesium_input_mol = transfer.magnesium_mol,
            .sodium_input_mol = transfer.sodium_mol,
            .potassium_input_mol = transfer.potassium_mol,
            .sulfur_input_mol = transfer.sulfur_mol,
            .chloride_input_mol = transfer.chloride_mol,
            .silicon_input_mol = transfer.silicon_mol,
            .sand_input_megagrams = transfer.sand_megagrams,
            .silt_input_megagrams = transfer.silt_megagrams,
            .clay_input_megagrams = transfer.clay_megagrams,
            .rock_additive_input = transfer.rock_additive,
            .cation_exchange_capacity_input_mol = transfer.cation_exchange_capacity_mol,
            .anion_exchange_capacity_input_mol = transfer.anion_exchange_capacity_mol,
        },
        .output => .{
            .water_output_m3 = transfer.water_m3,
            .heat_output_megajoules = transfer.heat_megajoules,
            .oxygen_output_g = transfer.oxygen_g,
            .hydrogen_output_g = transfer.hydrogen_g,
            .carbon_output_g = transfer.carbon_g,
            .nitrogen_output_g = transfer.nitrogen_g,
            .phosphorus_output_g = transfer.phosphorus_g,
            .aluminum_output_mol = transfer.aluminum_mol,
            .iron_output_mol = transfer.iron_mol,
            .calcium_output_mol = transfer.calcium_mol,
            .magnesium_output_mol = transfer.magnesium_mol,
            .sodium_output_mol = transfer.sodium_mol,
            .potassium_output_mol = transfer.potassium_mol,
            .sulfur_output_mol = transfer.sulfur_mol,
            .chloride_output_mol = transfer.chloride_mol,
            .silicon_output_mol = transfer.silicon_mol,
            .sand_output_megagrams = transfer.sand_megagrams,
            .silt_output_megagrams = transfer.silt_megagrams,
            .clay_output_megagrams = transfer.clay_megagrams,
            .rock_additive_output = transfer.rock_additive,
            .cation_exchange_capacity_output_mol = transfer.cation_exchange_capacity_mol,
            .anion_exchange_capacity_output_mol = transfer.anion_exchange_capacity_mol,
        },
    };
}

test "layout preserves separate soil snow surface and canopy scopes" {
    const layout = try Layout.init(2, 3, 4);
    try std.testing.expectEqual(@as(usize, 18), try layout.scopeCount());
    const addresses = [_]ScopeAddress{
        .{ .kind = .soil_layer, .cell = 1, .layer = 2 },
        .{ .kind = .snow_layer, .cell = 1, .layer = 3 },
        .{ .kind = .surface, .cell = 1 },
        .{ .kind = .canopy, .cell = 1 },
    };
    for (addresses) |address| {
        const index = try layout.index(address);
        try std.testing.expectEqualDeep(address, try layout.address(index));
    }
}

test "accepted runoff maps only to surface scopes and rolls back late invalid activity" {
    const layout = try Layout.init(2, 1, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    try accumulateSurfaceRunoffActivity(&ledger, &.{
        .{ .water_output_m3 = 2, .carbon_output_g = 3 },
        .{ .water_input_m3 = 2, .carbon_input_g = 3 },
    });
    const first_surface = try layout.index(.{ .kind = .surface, .cell = 0 });
    const second_surface = try layout.index(.{ .kind = .surface, .cell = 1 });
    try std.testing.expectEqual(@as(f64, 2), ledger.activity[first_surface].water_output_m3);
    try std.testing.expectEqual(@as(f64, 3), ledger.activity[first_surface].carbon_output_g);
    try std.testing.expectEqual(@as(f64, 2), ledger.activity[second_surface].water_input_m3);
    try std.testing.expectEqual(@as(f64, 3), ledger.activity[second_surface].carbon_input_g);
    for (0..try layout.soilCount() + try layout.snowCount()) |scope|
        try std.testing.expectEqualDeep(hourly.BoundaryActivity{}, ledger.activity[scope]);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(
        error.InvalidHourlyCellBoundaryActivity,
        accumulateSurfaceRunoffActivity(&ledger, &.{
            .{ .water_input_m3 = 1 },
            .{ .water_input_m3 = -1 },
        }),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "pond accepted transfers preserve actual surface and soil receivers atomically" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    var particulate_active = [_]bool{true};
    var particulate_destination = [_]usize{1};
    var particulate_transfer = [_]pond_conservation.Transfer{.{ .water_m3 = 1, .carbon_mol = 2 }};
    var soil_active = [_]bool{ false, true };
    var soil_destination = [_]usize{ 0, 0 };
    var soil_transfer = [_]pond_conservation.Transfer{ .{}, .{ .nitrogen_g = 3 } };
    var domain_active = [_]bool{true};
    var domain_destination = [_]usize{0};
    var domain_transfer = [_]pond_conservation.Transfer{.{ .phosphorus_mol = 4, .calcium_mol = 5 }};
    try accumulatePondAcceptedTransfers(
        &ledger,
        &.{2},
        .{ .active = &particulate_active, .destination_soil_layer = &particulate_destination, .transfer = &particulate_transfer },
        .{ .active_by_source = &soil_active, .destination_soil_layer_by_source = &soil_destination, .transfer_by_source = &soil_transfer },
        .{ .active = &domain_active, .destination_soil_layer = &domain_destination, .transfer = &domain_transfer },
        .{ .carbon = 12, .nitrogen = 14, .phosphorus = 31 },
    );
    const surface = ledger.activity[try layout.index(.{ .kind = .surface, .cell = 0 })];
    const soil0 = ledger.activity[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 })];
    const soil1 = ledger.activity[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 })];
    try std.testing.expectEqual(@as(f64, 1), surface.water_output_m3);
    try std.testing.expectEqual(@as(f64, 24), surface.carbon_output_g);
    try std.testing.expectEqual(@as(f64, 124), surface.phosphorus_output_g);
    try std.testing.expectEqual(@as(f64, 5), surface.calcium_output_mol);
    try std.testing.expectEqual(@as(f64, 3), soil0.nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 124), soil0.phosphorus_input_g);
    try std.testing.expectEqual(@as(f64, 5), soil0.calcium_input_mol);
    try std.testing.expectEqual(@as(f64, 1), soil1.water_input_m3);
    try std.testing.expectEqual(@as(f64, 24), soil1.carbon_input_g);
    try std.testing.expectEqual(@as(f64, 3), soil1.nitrogen_output_g);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    domain_destination[0] = 2;
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulatePondAcceptedTransfers(
            &ledger,
            &.{2},
            .{ .active = &particulate_active, .destination_soil_layer = &particulate_destination, .transfer = &particulate_transfer },
            .{ .active_by_source = &soil_active, .destination_soil_layer_by_source = &soil_destination, .transfer_by_source = &soil_transfer },
            .{ .active = &domain_active, .destination_soil_layer = &domain_destination, .transfer = &domain_transfer },
            .{ .carbon = 12, .nitrogen = 14, .phosphorus = 31 },
        ),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "suspended local exchange maps packed canonical composition by source layer" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    var organic_profile = try organic_state.State.init(std.testing.allocator, 2);
    defer organic_profile.deinit();
    const eroded_organic = @import("../soil/profile/erosion_organic_bridge.zig");
    const eroded_fertilizer = @import("../soil/profile/erosion_fertilizer_bridge.zig");
    const eroded_chemistry = @import("../soil/profile/erosion_chemistry_bridge.zig");
    const dry_fertilizer = @import("../management/mineral_fertilizer_inventory.zig");
    var state = try suspended.State.init(std.testing.allocator, 1, .{
        .organic_cnp_count = try eroded_organic.componentCount(&organic_profile),
        .nitrogen_fertilizer_count = eroded_fertilizer.component_count,
        .dry_mineral_fertilizer_count = @typeInfo(dry_fertilizer.Inventory).@"struct".fields.len,
        .chemistry_live_and_pending_count = eroded_chemistry.component_count,
    });
    defer state.deinit();
    state.local_sediment_to_suspension_megagrams[0] = 1;
    state.local_exchange_soil_layer_by_cell[0] = 1;
    state.local_transfer_to_suspension[0] = 0.2;
    state.local_transfer_to_suspension[1] = 0.3;
    state.local_transfer_to_suspension[2] = 0.5;
    try accumulateSuspendedLocalExchange(
        &ledger,
        &state,
        &organic_profile,
        &.{2},
        .{ .carbon = 12, .nitrogen = 14, .phosphorus = 31 },
    );
    const surface = ledger.activity[try layout.index(.{ .kind = .surface, .cell = 0 })];
    const soil1 = ledger.activity[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 })];
    try std.testing.expectEqual(@as(f64, 0.2), surface.sand_input_megagrams);
    try std.testing.expectEqual(@as(f64, 0.3), surface.silt_input_megagrams);
    try std.testing.expectEqual(@as(f64, 0.5), surface.clay_input_megagrams);
    try std.testing.expectEqual(@as(f64, 0.2), soil1.sand_output_megagrams);
    try std.testing.expectEqual(@as(f64, 0.3), soil1.silt_output_megagrams);
    try std.testing.expectEqual(@as(f64, 0.5), soil1.clay_output_megagrams);
}

test "fertilizer activity partitions surface and exact soil layer and rejects inactive receipt" {
    const layout = try Layout.init(2, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    var sidecar = try fertilizer_dispatch.LocalActivityState.init(std.testing.allocator, 2, 2);
    defer sidecar.deinit();
    sidecar.surface_by_cell[0].nitrogen_g_n = 1;
    sidecar.soil_by_layer[1].phosphorus_g_p = 2;
    sidecar.soil_by_layer[2].calcium_mol = 3;
    try accumulateFertilizerLocalActivity(&ledger, &sidecar, &.{ 2, 1 });
    try std.testing.expectEqual(
        @as(f64, 1),
        ledger.activity[try layout.index(.{ .kind = .surface, .cell = 0 })].nitrogen_input_g,
    );
    try std.testing.expectEqual(
        @as(f64, 2),
        ledger.activity[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 })].phosphorus_input_g,
    );
    try std.testing.expectEqual(
        @as(f64, 3),
        ledger.activity[try layout.index(.{ .kind = .soil_layer, .cell = 1, .layer = 0 })].calcium_input_mol,
    );

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    sidecar.soil_by_layer[3].carbon_g_c = 4;
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulateFertilizerLocalActivity(&ledger, &sidecar, &.{ 2, 1 }),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "plant litterfall pairs each cell canopy donor with its surface recipient atomically" {
    const layout = try Layout.init(2, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    try accumulatePlantLitterfall(
        &ledger,
        2,
        &.{ 1, 2, 4, 8 },
        &.{ 0.1, 0.2, 0.4, 0.8 },
        &.{ 0.01, 0.02, 0.04, 0.08 },
    );
    const canopy0 = ledger.activity[try layout.index(.{ .kind = .canopy, .cell = 0 })];
    const surface0 = ledger.activity[try layout.index(.{ .kind = .surface, .cell = 0 })];
    const canopy1 = ledger.activity[try layout.index(.{ .kind = .canopy, .cell = 1 })];
    const surface1 = ledger.activity[try layout.index(.{ .kind = .surface, .cell = 1 })];
    try std.testing.expectEqual(@as(f64, 3), canopy0.carbon_output_g);
    try std.testing.expectEqual(@as(f64, 3), surface0.carbon_input_g);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), canopy0.nitrogen_output_g, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.03), surface0.phosphorus_input_g, 1e-15);
    try std.testing.expectEqual(@as(f64, 12), canopy1.carbon_output_g);
    try std.testing.expectEqual(@as(f64, 12), surface1.carbon_input_g);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(
        error.InvalidLayerConservationActivity,
        accumulatePlantLitterfall(
            &ledger,
            2,
            &.{ 1, 2, 4, std.math.nan(f64) },
            &.{ 0.1, 0.2, 0.4, 0.8 },
            &.{ 0.01, 0.02, 0.04, 0.08 },
        ),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "plant internal root shoot sidecar closes C N P and salts at every layer" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    var sidecar = try plant_internal.State.init(std.testing.allocator, 1, 2);
    defer sidecar.deinit();
    var canopy_to_root: plant_internal.Transfer = .{
        .carbon_g_c = 2,
        .phosphorus_g_p = 0.25,
    };
    canopy_to_root.salt_mol[2] = 3;
    try sidecar.recordCanopyToRoot(0, 1, canopy_to_root);
    var root_to_canopy: plant_internal.Transfer = .{
        .nitrogen_g_n = 0.5,
    };
    root_to_canopy.salt_mol[7] = 4;
    try sidecar.recordRootToCanopy(0, 1, root_to_canopy);
    try accumulatePlantInternalRootShoot(&ledger, &sidecar, &.{2});
    const canopy = ledger.activity[try layout.index(.{ .kind = .canopy, .cell = 0 })];
    const root = ledger.activity[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 })];
    try std.testing.expectEqual(@as(f64, 2), canopy.carbon_output_g);
    try std.testing.expectEqual(@as(f64, 2), root.carbon_input_g);
    try std.testing.expectEqual(@as(f64, 0.5), root.nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 0.5), canopy.nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 3), canopy.calcium_output_mol);
    try std.testing.expectEqual(@as(f64, 3), root.calcium_input_mol);
    try std.testing.expectEqual(@as(f64, 4), root.chloride_output_mol);
    try std.testing.expectEqual(@as(f64, 4), canopy.chloride_input_mol);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    sidecar.root_to_canopy[0].carbon_g_c = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidLayerConservationActivity,
        accumulatePlantInternalRootShoot(&ledger, &sidecar, &.{2}),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
    sidecar.root_to_canopy[0].carbon_g_c = 0;
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulatePlantInternalRootShoot(&ledger, &sidecar, &.{1}),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "canopy atmospheric sidecar keeps gross directions and excludes unresolved drainage residuals" {
    const layout = try Layout.init(1, 1, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    var sidecar = try canopy_conservation.State.init(std.testing.allocator, 1, 1);
    defer sidecar.deinit();
    sidecar.activity_by_cell[0] = .{
        .atmospheric_water_input_m3 = 4,
        .atmospheric_water_output_m3 = 3,
        .drainage_water_to_lower_boundary_m3 = 2,
        .retained_precipitation_heat_input_megajoules = 5,
        .drainage_heat_to_lower_boundary_megajoules = 6,
        .residual_heat_input_megajoules = 7,
        .residual_heat_output_megajoules = 8,
    };
    try accumulateCanopyAtmosphericActivity(&ledger, &sidecar, 0.25);
    const canopy = ledger.activity[try layout.index(.{ .kind = .canopy, .cell = 0 })];
    try std.testing.expectEqual(@as(f64, 1), canopy.water_input_m3);
    try std.testing.expectEqual(@as(f64, 0.75), canopy.water_output_m3);
    try std.testing.expectEqual(@as(f64, 3), canopy.heat_input_megajoules);
    try std.testing.expectEqual(@as(f64, 2), canopy.heat_output_megajoules);
    const surface_index = try layout.index(.{ .kind = .surface, .cell = 0 });
    try std.testing.expectEqualDeep(hourly.BoundaryActivity{}, ledger.activity[surface_index]);

    // Once the lower router resolves the quarter-hour drainage owner, the
    // complete EXTRACT identity is ΔENGYC = retained enthalpy + THFLXC -
    // drainage enthalpy = (5 + 7 - 8 - 6) * 0.25 = -0.5 MJ.
    try accumulateAcceptedAtmosphericActivity(
        &ledger,
        &.{1},
        &.{false},
        &.{.{ .canopy_to_surface = .{ .heat_megajoules = 1.5 } }},
    );
    const closed_canopy = ledger.activity[try layout.index(.{ .kind = .canopy, .cell = 0 })];
    try std.testing.expectEqual(@as(f64, 3), closed_canopy.heat_input_megajoules);
    try std.testing.expectEqual(@as(f64, 3.5), closed_canopy.heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 1.5), ledger.activity[surface_index].heat_input_megajoules);
}

test "accepted atmosphere sidecar maps exact owners and paired canopy drainage atomically" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    const activity: atmospheric_local.CellActivity = .{
        .top_snow_external = .{ .water_input_m3 = 1, .heat_output_megajoules = 2 },
        .surface_external = .{ .nitrogen_input_g = 3 },
        .topsoil_external = .{ .water_output_m3 = 4 },
        .canopy_to_top_snow = .{ .water_m3 = 5, .heat_megajoules = 6 },
        .canopy_to_surface = .{ .carbon_g = 7 },
        .canopy_to_topsoil = .{ .phosphorus_g = 8 },
    };
    try accumulateAcceptedAtmosphericActivity(&ledger, &.{2}, &.{true}, &.{activity});
    const snow_activity = ledger.activity[try layout.index(.{ .kind = .snow_layer, .cell = 0, .layer = 0 })];
    const surface_activity = ledger.activity[try layout.index(.{ .kind = .surface, .cell = 0 })];
    const soil_activity = ledger.activity[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 })];
    const canopy_activity = ledger.activity[try layout.index(.{ .kind = .canopy, .cell = 0 })];
    try std.testing.expectEqual(@as(f64, 6), snow_activity.water_input_m3);
    try std.testing.expectEqual(@as(f64, 6), snow_activity.heat_input_megajoules);
    try std.testing.expectEqual(@as(f64, 2), snow_activity.heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 7), surface_activity.carbon_input_g);
    try std.testing.expectEqual(@as(f64, 3), surface_activity.nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 4), soil_activity.water_output_m3);
    try std.testing.expectEqual(@as(f64, 8), soil_activity.phosphorus_input_g);
    try std.testing.expectEqual(@as(f64, 5), canopy_activity.water_output_m3);
    try std.testing.expectEqual(@as(f64, 6), canopy_activity.heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 7), canopy_activity.carbon_output_g);
    try std.testing.expectEqual(@as(f64, 8), canopy_activity.phosphorus_output_g);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulateAcceptedAtmosphericActivity(&ledger, &.{2}, &.{false}, &.{activity}),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "production coverage never claims an unknown local activity family" {
    try std.testing.expect(production_required_activity != 0);
    try std.testing.expectEqual(
        @as(u32, 0),
        production_bound_activity & ~production_required_activity,
    );
    const sediment_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_sediment.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(sediment_source);
    inline for (.{
        "accumulateSuspendedLocalExchange(",
        "accumulateSurfaceErosionRoutingActivity(",
        "accumulatePondAcceptedTransfers(",
        "accumulateSurfaceOrganicHeatRebase(",
    }) |binding|
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, sediment_source, binding));
    const biogeochemistry_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/biogeochemistry_batches.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(biogeochemistry_source);
    inline for (.{
        "accumulateSoilMicrobialMixingActivity(",
        "accumulateSoilBiogeochemicalReactions(",
        "accumulateSurfaceBiogeochemicalActivity(",
        "accumulateSurfaceTopsoilMicrobialMixingActivity(",
        "accumulateSurfaceBiogeochemicalReactions(",
    }) |binding|
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, biogeochemistry_source, binding));
    const geometry_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_geometry_disturbance.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(geometry_source);
    inline for (.{
        "snapshot.binding(&activity_sidecar, science)",
        "accumulateSoilRelayeringActivity(",
    }) |binding|
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, geometry_source, binding));
    const production_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/ecosys_ng.zig",
        std.testing.allocator,
        .limited(16 * 1024 * 1024),
    );
    defer std.testing.allocator.free(production_source);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, production_source, "accumulateFertilizerLocalActivity("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, production_source, "accumulatePlantLitterfall("),
    );
    inline for (.{
        "accumulateRootGasActivity(",
        "accumulatePlantAtmosphereActivity(",
        "accumulateSoilSurfaceGasAtmosphere(",
        "accumulateCanopyHarvestSalt(",
        "accumulateCanopySurfaceManure(",
        "accumulateSoilSurfaceFireActivity(",
        "accumulateCanopySurfaceFireReturns(",
    }) |binding| try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, production_source, binding),
    );
    try std.testing.expect(std.mem.count(u8, production_source, "accumulateCanopyHarvest(") > 0);
    const vegetation_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_vegetation.zig",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(vegetation_source);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, vegetation_source, "accumulatePlantInternalRootShoot("),
    );
    const snow_stage_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_heat_water_solute.zig",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(snow_stage_source);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            snow_stage_source,
            "try self.advanceSourceOrderedSnowPhysics(time_step_hours, thermodynamics)",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            snow_stage_source,
            "try ecosys.layer_local_conservation.accumulateSnowTransportActivity(",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            snow_stage_source,
            "try self.accumulateAcceptedGasBubbleActivity();",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            snow_stage_source,
            "try ecosys.layer_local_conservation.accumulateSoilGasBubbleActivity(",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, snow_stage_source, "ecosys.snow_relayering.applyAccepted("),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, snow_stage_source, "ecosys.snow_relayering.apply("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, snow_stage_source, "self.snow_relayering_total.add(self.snow_relayering_step)"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            snow_stage_source,
            "try ecosys.layer_local_conservation.accumulateSnowRelayeringActivity(",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            snow_stage_source,
            "try ecosys.layer_local_conservation.accumulateSnowSurfaceSoilTransferActivity(",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, snow_stage_source, "try self.applySnowDischargeRecipientHeat(time_step_hours);"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, snow_stage_source, "snow_surface_transfer_heat.acceptedLitterCandidate("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            snow_stage_source,
            "try ecosys.layer_local_conservation.accumulateCellActivityAtSnowTop(",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, snow_stage_source, "try coupled_substeps.publishAcceptedSnowDrift();"),
    );
}

test "snow surface transfer source order binds physical chemistry disappearance and local publication once" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_heat_water_solute.zig",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);
    const prepare = std.mem.indexOf(u8, source, "noinline fn prepareSubstep(raw:") orelse
        return error.MissingAcceptedSnowSubstepPrepare;
    const accept = std.mem.indexOfPos(u8, source, prepare, "noinline fn acceptSubstep(raw:") orelse
        return error.MissingAcceptedSnowSubstepAccept;
    const prepare_body = source[prepare..accept];
    const snow_producer = std.mem.indexOf(u8, prepare_body, "advanceSnowBeforeSoil(time_step_hours)") orelse
        return error.MissingSnowSurfaceTransferProducer;
    const ingress = std.mem.indexOfPos(u8, prepare_body, snow_producer, "Forcing.prepareSubstep") orelse
        return error.MissingSnowSurfaceTransferWaterRecipient;
    const heat = std.mem.indexOfPos(u8, prepare_body, ingress, "applySnowDischargeRecipientHeat") orelse
        return error.MissingSnowSurfaceTransferHeatRecipient;
    try std.testing.expect(snow_producer < ingress and ingress < heat);

    const accept_end = std.mem.indexOfPos(u8, source, accept, "noinline fn acceptPhaseDisplacement") orelse
        return error.MissingAcceptedSnowSubstepAcceptEnd;
    const accept_body = source[accept..accept_end];
    const arm = std.mem.indexOf(u8, accept_body, "armSnowDisappearance") orelse
        return error.MissingSnowDisappearanceArm;
    const drift = std.mem.indexOfPos(u8, accept_body, arm, "advanceSnowDrift") orelse
        return error.MissingAcceptedSnowDrift;
    const disappearance = std.mem.indexOfPos(u8, accept_body, drift, "consumeSnowDisappearance") orelse
        return error.MissingSnowDisappearanceConsumer;
    const chemistry = std.mem.indexOfPos(u8, accept_body, disappearance, "applyAcceptedSurfaceDischarge") orelse
        return error.MissingSnowSurfaceChemistryRecipient;
    try std.testing.expect(arm < drift and drift < disappearance and disappearance < chemistry);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "for (disappearance.accepted_transfer_by_cell"),
    );
}

test "snow relayering accepted sidecar is accumulated and published in source order" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_heat_water_solute.zig",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);
    const owner = std.mem.indexOf(u8, source, "fn advanceSnowCompactionAndRelayering(") orelse
        return error.MissingSnowRelayeringOwner;
    const owner_end = std.mem.indexOfPos(u8, source, owner, "fn refreshSurfaceHeatCapacity(") orelse
        return error.MissingSnowRelayeringOwnerEnd;
    const body = source[owner..owner_end];
    const compaction = std.mem.indexOf(u8, body, "snow_compaction.apply(") orelse
        return error.MissingSnowCompactionOwner;
    const relayering = std.mem.indexOfPos(u8, body, compaction, "snow_relayering.applyAccepted(") orelse
        return error.MissingAcceptedSnowRelayeringOwner;
    const total = std.mem.indexOfPos(u8, body, relayering, "snow_relayering_total.add(") orelse
        return error.MissingAcceptedSnowRelayeringTotal;
    const touched = std.mem.indexOfPos(u8, body, total, "snow_relayering_step.touched_by_layer") orelse
        return error.MissingAcceptedSnowRelayeringTouchedScope;
    try std.testing.expect(compaction < relayering and relayering < total and total < touched);

    const publisher = std.mem.indexOf(u8, source, "fn publishAcceptedSnowSchedule(") orelse
        return error.MissingAcceptedSnowSchedulePublication;
    const publisher_end = std.mem.indexOfPos(u8, source, publisher, "fn publishAcceptedSnowDrift(") orelse
        return error.MissingAcceptedSnowSchedulePublicationEnd;
    const publication = source[publisher..publisher_end];
    const transport = std.mem.indexOf(u8, publication, "accumulateSnowTransportActivity(") orelse
        return error.MissingAcceptedSnowTransportPublication;
    const relayering_activity = std.mem.indexOfPos(u8, publication, transport, "accumulateSnowRelayeringActivity(") orelse
        return error.MissingAcceptedSnowRelayeringPublication;
    const surface = std.mem.indexOfPos(u8, publication, relayering_activity, "accumulateSnowSurfaceSoilTransferActivity(") orelse
        return error.MissingAcceptedSnowSurfaceTransferPublication;
    try std.testing.expect(transport < relayering_activity and relayering_activity < surface);

    const zero = std.mem.indexOf(u8, source, "fn zeroTotals(self: *Self)") orelse
        return error.MissingSnowScheduleTotalReset;
    const zero_end = std.mem.indexOfPos(u8, source, zero, "fn restoreSchedule(raw: *anyopaque)") orelse
        return error.MissingSnowScheduleTotalResetEnd;
    const reset = source[zero..zero_end];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, reset, "self.snow_relayering_step.reset()"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, reset, "self.snow_relayering_total.reset()"));
}

test "layer acceptance rejects exact within-column cancellation" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    const scope_count = try layout.scopeCount();
    const before = try std.testing.allocator.alloc(inventory.Storage, scope_count);
    defer std.testing.allocator.free(before);
    const after = try std.testing.allocator.alloc(inventory.Storage, scope_count);
    defer std.testing.allocator.free(after);
    const area = try std.testing.allocator.alloc(f64, scope_count);
    defer std.testing.allocator.free(area);
    @memset(before, .{});
    @memset(after, .{});
    @memset(area, 1);
    const upper = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    const lower = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 });
    before[upper].water_m3 = 10;
    before[lower].water_m3 = 10;
    after[upper].water_m3 = 10.01;
    after[lower].water_m3 = 9.99;
    var report = try evaluate(
        std.testing.allocator,
        before,
        after,
        ledger.activity,
        area,
        .{ .absolute_per_area = .{ .water_m = 1e-4 }, .relative = 1e-10 },
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(!report.accepted());
    try std.testing.expectEqual(@as(usize, 2), report.failing_cell_count[@intFromEnum(hourly.Quantity.water)]);
}

test "snow accepted producer activity closes each layer without column cancellation" {
    const layout = try Layout.init(2, 1, 3);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    const active = [_]bool{ true, true, false, true, true, false };
    const downward_water = [_]f64{ 0, 2, 0, 0, 0, 0 };
    const downward_liquid_heat = [_]f64{ 0, 5, 0, 0, 0, 0 };
    const conduction_heat = [_]f64{ 0, 3, 0, 0, 0, 0 };
    const vapor_water = [_]f64{ 0, 0, 0, 0, 0, 0 };
    const vapor_heat = [_]f64{ 0, 0, 0, 0, -0.75, 0 };
    // The second interface reverses during the accepted schedule. Its
    // independent net water and heat still equal downward minus upward, while
    // gross traffic remains visible in both ledger directions.
    const vapor_water_downward = [_]f64{ 0, 0, 0, 0, 0.50, 0 };
    const vapor_water_upward = [_]f64{ 0, 0, 0, 0, 0.50, 0 };
    const vapor_heat_downward = [_]f64{ 0, 0, 0, 0, 1.00, 0 };
    const vapor_heat_upward = [_]f64{ 0, 0, 0, 0, 1.75, 0 };
    const process_heat = [_]f64{ 0, 0, 0, 0, 4, 0 };
    const inactive_reference_heat = [_]f64{ 0, -2, 0, 0, 0, 0 };
    var accepted_g: [6 * snow.species_count]f64 = @splat(0);
    accepted_g[@intFromEnum(snow.Species.carbon_dioxide_carbon)] = 2;
    accepted_g[@intFromEnum(snow.Species.oxygen)] = 3;
    accepted_g[@intFromEnum(snow.Species.sulfate_sulfur)] = 32;
    var accepted_salt: [6 * snow.salt_species_count]f64 = @splat(0);
    const dynamic_source = 3 * snow.salt_species_count;
    accepted_salt[dynamic_source + @intFromEnum(snow.SaltSpecies.calcium_carbonate)] = 2;
    accepted_salt[dynamic_source + @intFromEnum(snow.SaltSpecies.phosphate)] = 1;
    const molar_mass: inventory.SnowMolarMassesGPerMol = .{
        .nitrogen = 14,
        .phosphorus = 31,
        .ions = .{ .aluminum = 27, .iron = 56, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 },
    };
    try accumulateSnowTransportActivity(&ledger, .{
        .active_by_layer = &active,
        .downward_liquid_water_m3_by_destination = &downward_water,
        .downward_liquid_heat_megajoules_by_destination = &downward_liquid_heat,
        .conduction_heat_megajoules_by_destination = &conduction_heat,
        .vapor_water_m3_by_destination = &vapor_water,
        .vapor_heat_megajoules_by_destination = &vapor_heat,
        .vapor_water_downward_m3_by_destination = &vapor_water_downward,
        .vapor_water_upward_m3_by_destination = &vapor_water_upward,
        .vapor_heat_downward_megajoules_by_destination = &vapor_heat_downward,
        .vapor_heat_upward_megajoules_by_destination = &vapor_heat_upward,
        .vapor_equilibrium_heat_megajoules_by_layer = &process_heat,
        .inactive_reference_heat_megajoules_by_layer = &inactive_reference_heat,
        .accepted_downward_g_by_source_species = &accepted_g,
        .accepted_downward_salt_mol_by_source_species = &accepted_salt,
        .dynamic_salts_by_cell = &.{ false, true },
        .molar_mass_g_per_mol = molar_mass,
    });

    const static_upper = ledger.activity[try layout.index(.{ .kind = .snow_layer, .cell = 0, .layer = 0 })];
    const static_lower = ledger.activity[try layout.index(.{ .kind = .snow_layer, .cell = 0, .layer = 1 })];
    try std.testing.expectEqual(@as(f64, 2), static_upper.water_output_m3);
    try std.testing.expectEqual(@as(f64, 8), static_upper.heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 2), static_upper.carbon_output_g);
    try std.testing.expectEqual(@as(f64, 3), static_upper.oxygen_output_g);
    try std.testing.expectEqual(@as(f64, 1), static_upper.sulfur_output_mol);
    try std.testing.expectEqual(static_upper.water_output_m3, static_lower.water_input_m3);
    try std.testing.expectEqual(static_upper.heat_output_megajoules, static_lower.heat_input_megajoules);
    try std.testing.expectEqual(@as(f64, 2), static_lower.heat_internal_consumption_megajoules);
    try std.testing.expectEqual(static_upper.carbon_output_g, static_lower.carbon_input_g);
    try std.testing.expectEqual(static_upper.oxygen_output_g, static_lower.oxygen_input_g);
    try std.testing.expectEqual(static_upper.sulfur_output_mol, static_lower.sulfur_input_mol);

    const dynamic_upper = ledger.activity[try layout.index(.{ .kind = .snow_layer, .cell = 1, .layer = 0 })];
    const dynamic_lower = ledger.activity[try layout.index(.{ .kind = .snow_layer, .cell = 1, .layer = 1 })];
    try std.testing.expectEqual(@as(f64, 0.50), dynamic_upper.water_input_m3);
    try std.testing.expectEqual(@as(f64, 0.50), dynamic_upper.water_output_m3);
    try std.testing.expectEqual(@as(f64, 1.75), dynamic_upper.heat_input_megajoules);
    try std.testing.expectEqual(@as(f64, 1.00), dynamic_upper.heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 24), dynamic_upper.carbon_output_g);
    try std.testing.expectEqual(@as(f64, 31), dynamic_upper.phosphorus_output_g);
    try std.testing.expectEqual(@as(f64, 2), dynamic_upper.calcium_output_mol);
    try std.testing.expectEqual(dynamic_upper.water_input_m3, dynamic_lower.water_output_m3);
    try std.testing.expectEqual(dynamic_upper.water_output_m3, dynamic_lower.water_input_m3);
    try std.testing.expectEqual(dynamic_upper.heat_input_megajoules, dynamic_lower.heat_output_megajoules);
    try std.testing.expectEqual(dynamic_upper.heat_output_megajoules, dynamic_lower.heat_input_megajoules);
    try std.testing.expectEqual(dynamic_upper.carbon_output_g, dynamic_lower.carbon_input_g);
    try std.testing.expectEqual(dynamic_upper.phosphorus_output_g, dynamic_lower.phosphorus_input_g);
    try std.testing.expectEqual(dynamic_upper.calcium_output_mol, dynamic_lower.calcium_input_mol);
    try std.testing.expectEqual(@as(f64, 4), dynamic_lower.heat_internal_production_megajoules);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    accepted_salt[(3 + 1) * snow.salt_species_count + @intFromEnum(snow.SaltSpecies.calcium)] = 1;
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulateSnowTransportActivity(&ledger, .{
            .active_by_layer = &active,
            .downward_liquid_water_m3_by_destination = &downward_water,
            .downward_liquid_heat_megajoules_by_destination = &downward_liquid_heat,
            .conduction_heat_megajoules_by_destination = &conduction_heat,
            .vapor_water_m3_by_destination = &vapor_water,
            .vapor_heat_megajoules_by_destination = &vapor_heat,
            .vapor_water_downward_m3_by_destination = &vapor_water_downward,
            .vapor_water_upward_m3_by_destination = &vapor_water_upward,
            .vapor_heat_downward_megajoules_by_destination = &vapor_heat_downward,
            .vapor_heat_upward_megajoules_by_destination = &vapor_heat_upward,
            .vapor_equilibrium_heat_megajoules_by_layer = &process_heat,
            .inactive_reference_heat_megajoules_by_layer = &inactive_reference_heat,
            .accepted_downward_g_by_source_species = &accepted_g,
            .accepted_downward_salt_mol_by_source_species = &accepted_salt,
            .dynamic_salts_by_cell = &.{ false, true },
            .molar_mass_g_per_mol = molar_mass,
        }),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "snow relayering publishes gross bidirectional phase heat and chemistry transfers atomically" {
    const layout = try Layout.init(1, 1, 2);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    var transfers = try snow_relayering.AcceptedTransfers.init(std.testing.allocator, 2);
    defer transfers.deinit();
    transfers.touched_by_layer[0] = true;
    transfers.touched_by_layer[1] = true;

    transfers.downward.solid_snow_water_equivalent_m3[1] = 0.2;
    transfers.downward.liquid_water_m3[1] = 0.1;
    transfers.downward.vapor_water_equivalent_m3[1] = 0.05;
    transfers.downward.ice_volume_m3[1] = 0.02;
    transfers.downward.sensible_heat_megajoules[1] = 20;
    transfers.downward.amount_g[@intFromEnum(snow.Species.carbon_dioxide_carbon) + snow.species_count] = 10;
    transfers.downward.salt_amount_mol[@intFromEnum(snow.SaltSpecies.calcium_carbonate) + snow.salt_species_count] = 2;

    transfers.upward.solid_snow_water_equivalent_m3[1] = 0.3;
    transfers.upward.liquid_water_m3[1] = 0.2;
    transfers.upward.vapor_water_equivalent_m3[1] = 0.1;
    transfers.upward.ice_volume_m3[1] = 0.04;
    transfers.upward.sensible_heat_megajoules[1] = 30;
    transfers.upward.amount_g[@intFromEnum(snow.Species.carbon_dioxide_carbon) + snow.species_count] = 4;
    transfers.upward.salt_amount_mol[@intFromEnum(snow.SaltSpecies.calcium_carbonate) + snow.salt_species_count] = 0.5;

    const molar_mass: inventory.SnowMolarMassesGPerMol = .{
        .nitrogen = 14,
        .phosphorus = 31,
        .ions = .{ .aluminum = 27, .iron = 56, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 },
    };
    const valid: SnowRelayeringActivity = .{
        .active_by_layer = &.{ true, true },
        .transfers = &transfers,
        .dynamic_salts_by_cell = &.{true},
        .ice_density_megagrams_per_m3 = 0.917,
        .latent_heat_of_fusion_megajoules_per_m3 = 333,
        .thermodynamics = snow.test_thermodynamics,
        .molar_mass_g_per_mol = molar_mass,
    };
    try accumulateSnowRelayeringActivity(&ledger, valid);
    const upper = ledger.activity[try layout.index(.{ .kind = .snow_layer, .cell = 0, .layer = 0 })];
    const lower = ledger.activity[try layout.index(.{ .kind = .snow_layer, .cell = 0, .layer = 1 })];
    const downward_water = 0.2 + 0.1 + 0.05 + 0.02 * 0.917;
    const upward_water = 0.3 + 0.2 + 0.1 + 0.04 * 0.917;
    try std.testing.expectApproxEqAbs(downward_water, upper.water_output_m3, 64 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(downward_water, lower.water_input_m3, 64 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(upward_water, lower.water_output_m3, 64 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(upward_water, upper.water_input_m3, 64 * std.math.floatEps(f64));
    try std.testing.expect(upper.heat_output_megajoules > 20);
    try std.testing.expect(lower.heat_output_megajoules > 30);
    try std.testing.expectEqual(upper.heat_output_megajoules, lower.heat_input_megajoules);
    try std.testing.expectEqual(lower.heat_output_megajoules, upper.heat_input_megajoules);
    try std.testing.expectEqual(@as(f64, 34), upper.carbon_output_g);
    try std.testing.expectEqual(@as(f64, 10), upper.carbon_input_g);
    try std.testing.expectEqual(@as(f64, 2), upper.calcium_output_mol);
    try std.testing.expectEqual(@as(f64, 0.5), upper.calcium_input_mol);
    try std.testing.expectEqual(upper.carbon_output_g, lower.carbon_input_g);
    try std.testing.expectEqual(upper.carbon_input_g, lower.carbon_output_g);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    var inactive = valid;
    inactive.active_by_layer = &.{ true, false };
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulateSnowRelayeringActivity(&ledger, inactive),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "snow drift producer activity maps verbatim to top layers and rejects inactive receipt" {
    const layout = try Layout.init(2, 1, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    const transfer: hourly.BoundaryActivity = .{
        .water_output_m3 = 2,
        .heat_output_megajoules = 3,
        .carbon_output_g = 4,
    };
    const receipt: hourly.BoundaryActivity = .{
        .water_input_m3 = 2,
        .heat_input_megajoules = 3,
        .carbon_input_g = 4,
    };
    try accumulateCellActivityAtSnowTop(
        &ledger,
        &.{ true, true },
        &.{ transfer, receipt },
    );
    try std.testing.expectEqualDeep(
        transfer,
        ledger.activity[try layout.index(.{ .kind = .snow_layer, .cell = 0, .layer = 0 })],
    );
    try std.testing.expectEqualDeep(
        receipt,
        ledger.activity[try layout.index(.{ .kind = .snow_layer, .cell = 1, .layer = 0 })],
    );
    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulateCellActivityAtSnowTop(
            &ledger,
            &.{ true, false },
            &.{ hourly.BoundaryActivity{}, receipt },
        ),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "snow external direction oracle preserves top directions and accepted bottom donor" {
    const layout = try Layout.init(1, 1, 2);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    var atmospheric_g: [snow.species_count]f64 = @splat(0);
    atmospheric_g[@intFromEnum(snow.Species.carbon_dioxide_carbon)] = 7;
    atmospheric_g[@intFromEnum(snow.Species.sulfate_sulfur)] = 64;
    var discharge_g: [2 * snow.species_count]f64 = @splat(0);
    discharge_g[snow.species_count + @intFromEnum(snow.Species.carbon_dioxide_carbon)] = 10;
    discharge_g[snow.species_count + @intFromEnum(snow.Species.sulfate_sulfur)] = 32;
    const atmospheric_salt: [snow.salt_species_count]f64 = @splat(0);
    const discharge_salt: [2 * snow.salt_species_count]f64 = @splat(0);
    const molar_mass: inventory.SnowMolarMassesGPerMol = .{
        .nitrogen = 14,
        .phosphorus = 31,
        .ions = .{ .aluminum = 27, .iron = 56, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 },
    };
    try accumulateSnowExternalDirectionOracle(&ledger, .{
        .active_by_layer = &.{ true, true },
        .atmospheric_solid_water_m3_by_cell = &.{1},
        .atmospheric_liquid_water_m3_by_cell = &.{2},
        .atmospheric_heat_megajoules_by_cell = &.{3},
        .surface_evaporation_m3_by_cell = &.{4},
        .surface_condensation_m3_by_cell = &.{5},
        .surface_boundary_heat_megajoules_by_cell = &.{-6},
        .atmospheric_input_g_by_cell_species = &atmospheric_g,
        .atmospheric_input_salt_mol_by_cell_species = &atmospheric_salt,
        .discharge_water_m3_by_source_layer = &.{ 0, 8 },
        .discharge_heat_megajoules_by_source_layer = &.{ 0, 9 },
        .discharge_g_by_source_layer_species = &discharge_g,
        .discharge_salt_mol_by_source_layer_species = &discharge_salt,
        .dynamic_salts_by_cell = &.{false},
        .molar_mass_g_per_mol = molar_mass,
    });
    const top = ledger.activity[try layout.index(.{ .kind = .snow_layer, .cell = 0, .layer = 0 })];
    const bottom = ledger.activity[try layout.index(.{ .kind = .snow_layer, .cell = 0, .layer = 1 })];
    try std.testing.expectEqual(@as(f64, 8), top.water_input_m3);
    try std.testing.expectEqual(@as(f64, 4), top.water_output_m3);
    try std.testing.expectEqual(@as(f64, 3), top.heat_input_megajoules);
    try std.testing.expectEqual(@as(f64, 6), top.heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 7), top.carbon_input_g);
    try std.testing.expectEqual(@as(f64, 2), top.sulfur_input_mol);
    try std.testing.expectEqual(@as(f64, 8), bottom.water_output_m3);
    try std.testing.expectEqual(@as(f64, 9), bottom.heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 10), bottom.carbon_output_g);
    try std.testing.expectEqual(@as(f64, 1), bottom.sulfur_output_mol);
}

test "snow surface soil transfer pairs accepted donor layer with exact physical and chemistry recipients" {
    const layout = try Layout.init(1, 1, 2);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    var donor_g: [2 * snow.species_count]f64 = @splat(0);
    donor_g[snow.species_count + @intFromEnum(snow.Species.carbon_dioxide_carbon)] = 10;
    donor_g[snow.species_count + @intFromEnum(snow.Species.ammonium_nitrogen)] = 14;
    donor_g[snow.species_count + @intFromEnum(snow.Species.sulfate_sulfur)] = 32;
    const donor_salt: [2 * snow.salt_species_count]f64 = @splat(0);
    var discharge: [1]snow.SurfaceDischarge = .{.{}};
    discharge[0].litter_g[@intFromEnum(snow.Species.carbon_dioxide_carbon)] = 4;
    discharge[0].soil_nonband_g[@intFromEnum(snow.Species.carbon_dioxide_carbon)] = 5;
    discharge[0].soil_band_g[@intFromEnum(snow.Species.carbon_dioxide_carbon)] = 1;
    discharge[0].litter_g[@intFromEnum(snow.Species.ammonium_nitrogen)] = 7;
    discharge[0].soil_band_g[@intFromEnum(snow.Species.ammonium_nitrogen)] = 7;
    discharge[0].soil_nonband_g[@intFromEnum(snow.Species.sulfate_sulfur)] = 32;
    const molar_mass: inventory.SnowMolarMassesGPerMol = .{
        .nitrogen = 14,
        .phosphorus = 31,
        .ions = .{ .aluminum = 27, .iron = 56, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 },
    };
    try accumulateSnowSurfaceSoilTransferActivity(&ledger, .{
        .active_snow_by_layer = &.{ true, true },
        .active_soil_layer_count_by_cell = &.{1},
        .donor_water_m3_by_snow_layer = &.{ 0, 8 },
        .donor_heat_megajoules_by_snow_layer = &.{ 0, 9 },
        .donor_g_by_snow_layer_species = &donor_g,
        .donor_salt_mol_by_snow_layer_species = &donor_salt,
        .surface_water_m3_by_cell = &.{3},
        .topsoil_water_m3_by_cell = &.{5},
        .surface_heat_megajoules_by_cell = &.{4},
        .topsoil_heat_megajoules_by_cell = &.{5},
        .accepted_chemistry_by_cell = &discharge,
        .dynamic_salts_by_cell = &.{false},
        .molar_mass_g_per_mol = molar_mass,
    });
    const donor = ledger.activity[try layout.index(.{ .kind = .snow_layer, .cell = 0, .layer = 1 })];
    const surface = ledger.activity[try layout.index(.{ .kind = .surface, .cell = 0 })];
    const topsoil = ledger.activity[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 })];
    try std.testing.expectEqual(@as(f64, 8), donor.water_output_m3);
    try std.testing.expectEqual(@as(f64, 9), donor.heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 10), donor.carbon_output_g);
    try std.testing.expectEqual(@as(f64, 14), donor.nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 1), donor.sulfur_output_mol);
    try std.testing.expectEqual(@as(f64, 3), surface.water_input_m3);
    try std.testing.expectEqual(@as(f64, 4), surface.heat_input_megajoules);
    try std.testing.expectEqual(@as(f64, 4), surface.carbon_input_g);
    try std.testing.expectEqual(@as(f64, 7), surface.nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 5), topsoil.water_input_m3);
    try std.testing.expectEqual(@as(f64, 5), topsoil.heat_input_megajoules);
    try std.testing.expectEqual(@as(f64, 6), topsoil.carbon_input_g);
    try std.testing.expectEqual(@as(f64, 7), topsoil.nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 1), topsoil.sulfur_input_mol);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(
        error.UnpairedSnowSurfaceSoilTransfer,
        accumulateSnowSurfaceSoilTransferActivity(&ledger, .{
            .active_snow_by_layer = &.{ true, true },
            .active_soil_layer_count_by_cell = &.{1},
            .donor_water_m3_by_snow_layer = &.{ 0, 8 },
            .donor_heat_megajoules_by_snow_layer = &.{ 0, 9 },
            .donor_g_by_snow_layer_species = &donor_g,
            .donor_salt_mol_by_snow_layer_species = &donor_salt,
            .surface_water_m3_by_cell = &.{2},
            .topsoil_water_m3_by_cell = &.{5},
            .surface_heat_megajoules_by_cell = &.{4},
            .topsoil_heat_megajoules_by_cell = &.{5},
            .accepted_chemistry_by_cell = &discharge,
            .dynamic_salts_by_cell = &.{false},
            .molar_mass_g_per_mol = molar_mass,
        }),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "snow surface soil transfer preserves dynamic salt stoichiometry and inactive recipient rejection" {
    const layout = try Layout.init(1, 1, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    const donor_g: [snow.species_count]f64 = @splat(0);
    var donor_salt: [snow.salt_species_count]f64 = @splat(0);
    donor_salt[@intFromEnum(snow.SaltSpecies.calcium_carbonate)] = 2;
    donor_salt[@intFromEnum(snow.SaltSpecies.phosphate)] = 1;
    var discharge: [1]snow.SurfaceDischarge = .{.{}};
    discharge[0].litter_salt_mol[@intFromEnum(snow.SaltSpecies.calcium_carbonate)] = 0.5;
    discharge[0].soil_nonband_salt_mol[@intFromEnum(snow.SaltSpecies.calcium_carbonate)] = 1;
    discharge[0].soil_band_salt_mol[@intFromEnum(snow.SaltSpecies.calcium_carbonate)] = 0.5;
    discharge[0].litter_salt_mol[@intFromEnum(snow.SaltSpecies.phosphate)] = 1;
    const molar_mass: inventory.SnowMolarMassesGPerMol = .{
        .nitrogen = 14,
        .phosphorus = 31,
        .ions = .{ .aluminum = 27, .iron = 56, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 },
    };
    const valid: SnowSurfaceSoilTransferActivity = .{
        .active_snow_by_layer = &.{true},
        .active_soil_layer_count_by_cell = &.{1},
        .donor_water_m3_by_snow_layer = &.{1},
        .donor_heat_megajoules_by_snow_layer = &.{2},
        .donor_g_by_snow_layer_species = &donor_g,
        .donor_salt_mol_by_snow_layer_species = &donor_salt,
        .surface_water_m3_by_cell = &.{0.25},
        .topsoil_water_m3_by_cell = &.{0.75},
        .surface_heat_megajoules_by_cell = &.{0.5},
        .topsoil_heat_megajoules_by_cell = &.{1.5},
        .accepted_chemistry_by_cell = &discharge,
        .dynamic_salts_by_cell = &.{true},
        .molar_mass_g_per_mol = molar_mass,
    };
    try accumulateSnowSurfaceSoilTransferActivity(&ledger, valid);
    const donor = ledger.activity[try layout.index(.{ .kind = .snow_layer, .cell = 0, .layer = 0 })];
    const surface = ledger.activity[try layout.index(.{ .kind = .surface, .cell = 0 })];
    const topsoil = ledger.activity[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 })];
    try std.testing.expectEqual(@as(f64, 24), donor.carbon_output_g);
    try std.testing.expectEqual(@as(f64, 31), donor.phosphorus_output_g);
    try std.testing.expectEqual(@as(f64, 2), donor.calcium_output_mol);
    try std.testing.expectEqual(@as(f64, 6), surface.carbon_input_g);
    try std.testing.expectEqual(@as(f64, 31), surface.phosphorus_input_g);
    try std.testing.expectEqual(@as(f64, 0.5), surface.calcium_input_mol);
    try std.testing.expectEqual(@as(f64, 18), topsoil.carbon_input_g);
    try std.testing.expectEqual(@as(f64, 1.5), topsoil.calcium_input_mol);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    var inactive = valid;
    inactive.active_soil_layer_count_by_cell = &.{0};
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulateSnowSurfaceSoilTransferActivity(&ledger, inactive),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "process transfer closes donor and recipient without reduction" {
    const layout = try Layout.init(1, 1, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    const donor: ScopeAddress = .{ .kind = .canopy, .cell = 0 };
    const recipient: ScopeAddress = .{ .kind = .surface, .cell = 0 };
    try ledger.accumulateTransfer(donor, recipient, .{ .carbon_g = 2 });
    const scope_count = try layout.scopeCount();
    const before = try std.testing.allocator.alloc(inventory.Storage, scope_count);
    defer std.testing.allocator.free(before);
    const after = try std.testing.allocator.alloc(inventory.Storage, scope_count);
    defer std.testing.allocator.free(after);
    const area = try std.testing.allocator.alloc(f64, scope_count);
    defer std.testing.allocator.free(area);
    @memset(before, .{});
    @memset(after, .{});
    @memset(area, 1);
    before[try layout.index(donor)].plant_carbon_g = 5;
    after[try layout.index(donor)].plant_carbon_g = 3;
    after[try layout.index(recipient)].residue_carbon_g = 2;
    var report = try evaluate(
        std.testing.allocator,
        before,
        after,
        ledger.activity,
        area,
        .{ .absolute_per_area = .{ .carbon_g_m2 = 1e-12 }, .relative = 1e-10 },
    );
    defer report.deinit(std.testing.allocator);
    try requireAccepted(report);
}

test "source-defined ROCK additive closes donor and recipient soil layers" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    const donor: ScopeAddress = .{ .kind = .soil_layer, .cell = 0, .layer = 0 };
    const recipient: ScopeAddress = .{ .kind = .soil_layer, .cell = 0, .layer = 1 };
    try ledger.accumulateTransfer(donor, recipient, .{ .rock_additive = 0.25 });
    const scope_count = try layout.scopeCount();
    const before = try std.testing.allocator.alloc(inventory.Storage, scope_count);
    defer std.testing.allocator.free(before);
    const after = try std.testing.allocator.alloc(inventory.Storage, scope_count);
    defer std.testing.allocator.free(after);
    const area = try std.testing.allocator.alloc(f64, scope_count);
    defer std.testing.allocator.free(area);
    @memset(before, .{});
    @memset(after, .{});
    @memset(area, 1);
    before[try layout.index(donor)].rock_additive = 0.75;
    before[try layout.index(recipient)].rock_additive = 0.5;
    after[try layout.index(donor)].rock_additive = 0.5;
    after[try layout.index(recipient)].rock_additive = 0.75;
    var report = try evaluate(
        std.testing.allocator,
        before,
        after,
        ledger.activity,
        area,
        .{ .absolute_per_area = .{ .rock_additive_m2 = 1e-12 }, .relative = 1e-10 },
    );
    defer report.deinit(std.testing.allocator);
    try requireAccepted(report);
}

test "root water transfer and source-signed heat close at every layer" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    try accumulateRootWaterHeatUptake(
        &ledger,
        &.{2},
        &.{ -1, 0.25 },
        &.{ -10, 2.5 },
    );
    const upper = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    const lower = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 });
    const canopy = try layout.index(.{ .kind = .canopy, .cell = 0 });
    try std.testing.expectEqual(@as(f64, 1), ledger.activity[upper].water_output_m3);
    try std.testing.expectEqual(@as(f64, 10), ledger.activity[upper].heat_internal_consumption_megajoules);
    try std.testing.expectEqual(@as(f64, 0.25), ledger.activity[lower].water_input_m3);
    try std.testing.expectEqual(@as(f64, 2.5), ledger.activity[lower].heat_internal_production_megajoules);
    try std.testing.expectEqual(@as(f64, 1), ledger.activity[canopy].water_input_m3);
    try std.testing.expectEqual(@as(f64, 0.25), ledger.activity[canopy].water_output_m3);
    // The canopy's accepted atmospheric owner closes the net root supply.
    try ledger.accumulate(.{ .kind = .canopy, .cell = 0 }, .{ .water_output_m3 = 0.75 });

    const scope_count = try layout.scopeCount();
    const before = try std.testing.allocator.alloc(inventory.Storage, scope_count);
    defer std.testing.allocator.free(before);
    const after = try std.testing.allocator.alloc(inventory.Storage, scope_count);
    defer std.testing.allocator.free(after);
    const area = try std.testing.allocator.alloc(f64, scope_count);
    defer std.testing.allocator.free(area);
    @memset(before, .{});
    @memset(after, .{});
    @memset(area, 1);
    before[upper] = .{ .water_m3 = 5, .heat_megajoules = 100 };
    after[upper] = .{ .water_m3 = 4, .heat_megajoules = 90 };
    before[lower] = .{ .water_m3 = 5, .heat_megajoules = 100 };
    after[lower] = .{ .water_m3 = 5.25, .heat_megajoules = 102.5 };
    var report = try evaluate(
        std.testing.allocator,
        before,
        after,
        ledger.activity,
        area,
        .{
            .absolute_per_area = .{ .water_m = 1e-12, .heat_megajoules_m2 = 1e-12 },
            .relative = 1e-10,
        },
    );
    defer report.deinit(std.testing.allocator);
    try requireAccepted(report);
}

test "root water layer publication rejects an inactive or mismatched pair atomically" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    ledger.activity[try layout.index(.{ .kind = .surface, .cell = 0 })].water_input_m3 = 1;
    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulateRootWaterHeatUptake(&ledger, &.{1}, &.{ 0, -1 }, &.{ 0, -10 }),
    );
    try std.testing.expectEqualDeep(before, ledger.activity);
    try std.testing.expectError(
        error.InvalidLayerConservationRootWaterHeatPair,
        accumulateRootWaterHeatUptake(&ledger, &.{1}, &.{ -1, 0 }, &.{ 10, 0 }),
    );
    try std.testing.expectEqualDeep(before, ledger.activity);
}

test "root gas atmosphere withdrawal and respiration close at their exact layers" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    const zero = [_]f64{ 0, 0 };
    const atmosphere: [root_atmosphere.gas_count][]const f64 = .{
        &.{ 3, -1 },
        &.{ 2, 0 },
        &zero,
        &.{ -2, 0 },
        &zero,
        &.{ 4, 0 },
    };
    const withdrawal: [root_withdrawal.gas_count][]const f64 = .{
        &.{ -1, 0 },
        &.{ -0.5, 0 },
        &zero,
        &zero,
        &.{ -1, 0 },
        &.{ -0.5, 0 },
    };
    try accumulateRootGasActivity(&ledger, .{
        .active_soil_layer_count = &.{2},
        .atmosphere_exchange_g_per_h_by_gas_and_layer = atmosphere,
        .withdrawal_loss_g_per_h_by_gas_and_layer = withdrawal,
        .soil_oxygen_uptake_g_o_per_h = &.{ 1, 0 },
        .root_pool_oxygen_uptake_g_o_per_h = &.{ 0.25, 0 },
    });
    const upper = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    const lower = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 });
    try std.testing.expectEqual(@as(f64, 3), ledger.activity[upper].carbon_input_g);
    try std.testing.expectEqual(@as(f64, 1), ledger.activity[upper].carbon_output_g);
    try std.testing.expectEqual(@as(f64, 2), ledger.activity[upper].oxygen_input_g);
    try std.testing.expectEqual(@as(f64, 0.5), ledger.activity[upper].oxygen_output_g);
    try std.testing.expectEqual(@as(f64, 1.25), ledger.activity[upper].oxygen_internal_consumption_g);
    try std.testing.expectEqual(@as(f64, 3), ledger.activity[upper].nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 4), ledger.activity[upper].hydrogen_input_g);
    try std.testing.expectEqual(@as(f64, 0.5), ledger.activity[upper].hydrogen_output_g);
    try std.testing.expectEqual(@as(f64, 1), ledger.activity[lower].carbon_output_g);

    const scope_count = try layout.scopeCount();
    const before = try std.testing.allocator.alloc(inventory.Storage, scope_count);
    defer std.testing.allocator.free(before);
    const after = try std.testing.allocator.alloc(inventory.Storage, scope_count);
    defer std.testing.allocator.free(after);
    const area = try std.testing.allocator.alloc(f64, scope_count);
    defer std.testing.allocator.free(area);
    @memset(before, .{});
    @memset(after, .{});
    @memset(area, 1);
    before[upper] = .{
        .carbon_dioxide_carbon_g = 10,
        .oxygen_g = 10,
        .dinitrogen_nitrogen_g = 10,
        .hydrogen_g = 10,
    };
    after[upper] = .{
        .carbon_dioxide_carbon_g = 12,
        .oxygen_g = 10.25,
        .dinitrogen_nitrogen_g = 7,
        .hydrogen_g = 13.5,
    };
    before[lower].carbon_dioxide_carbon_g = 10;
    after[lower].carbon_dioxide_carbon_g = 9;
    var report = try evaluate(
        std.testing.allocator,
        before,
        after,
        ledger.activity,
        area,
        .{ .absolute_per_area = .{
            .oxygen_g_m2 = 1e-12,
            .hydrogen_g_m2 = 1e-12,
            .carbon_g_m2 = 1e-12,
            .nitrogen_g_m2 = 1e-12,
        }, .relative = 1e-10 },
    );
    defer report.deinit(std.testing.allocator);
    try requireAccepted(report);
}

test "root gas local publication rejects late inactive activity atomically" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    ledger.activity[try layout.index(.{ .kind = .surface, .cell = 0 })].carbon_input_g = 7;
    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    const zero = [_]f64{ 0, 0 };
    const bad = [_]f64{ 0, 1 };
    const atmosphere: [root_atmosphere.gas_count][]const f64 = .{ &zero, &zero, &zero, &zero, &zero, &bad };
    const withdrawal: [root_withdrawal.gas_count][]const f64 = .{ &zero, &zero, &zero, &zero, &zero, &zero };
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulateRootGasActivity(&ledger, .{
            .active_soil_layer_count = &.{1},
            .atmosphere_exchange_g_per_h_by_gas_and_layer = atmosphere,
            .withdrawal_loss_g_per_h_by_gas_and_layer = withdrawal,
            .soil_oxygen_uptake_g_o_per_h = &zero,
            .root_pool_oxygen_uptake_g_o_per_h = &zero,
        }),
    );
    try std.testing.expectEqualDeep(before, ledger.activity);
}

test "plant atmosphere keeps shoot and root fixation in their storage scopes" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    try accumulatePlantAtmosphereActivity(
        &ledger,
        &.{.{
            .carbon_input_g = 5,
            .oxygen_output_g = 2,
            .oxygen_internal_production_g = 2,
            .nitrogen_input_g = 1,
        }},
        &.{2},
        &.{ 0.75, 0.25 },
    );
    const canopy = try layout.index(.{ .kind = .canopy, .cell = 0 });
    const upper = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    const lower = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 });
    try std.testing.expectEqual(@as(f64, 5), ledger.activity[canopy].carbon_input_g);
    try std.testing.expectEqual(@as(f64, 1), ledger.activity[canopy].nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 0.75), ledger.activity[upper].nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 0.25), ledger.activity[lower].nitrogen_input_g);

    const scope_count = try layout.scopeCount();
    const before = try std.testing.allocator.alloc(inventory.Storage, scope_count);
    defer std.testing.allocator.free(before);
    const after = try std.testing.allocator.alloc(inventory.Storage, scope_count);
    defer std.testing.allocator.free(after);
    const area = try std.testing.allocator.alloc(f64, scope_count);
    defer std.testing.allocator.free(area);
    @memset(before, .{});
    @memset(after, .{});
    @memset(area, 1);
    after[canopy].plant_carbon_g = 5;
    after[canopy].plant_nitrogen_g = 1;
    after[upper].plant_nitrogen_g = 0.75;
    after[lower].plant_nitrogen_g = 0.25;
    var report = try evaluate(
        std.testing.allocator,
        before,
        after,
        ledger.activity,
        area,
        .{ .absolute_per_area = .{
            .oxygen_g_m2 = 1e-12,
            .carbon_g_m2 = 1e-12,
            .nitrogen_g_m2 = 1e-12,
        }, .relative = 1e-10 },
    );
    defer report.deinit(std.testing.allocator);
    try requireAccepted(report);
}

test "axis two water heat face closes each soil layer" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    var axes = [_]u2{2};
    var slot_source = [_]usize{0};
    var slot_destination = [_]usize{1};
    var active_face = [_]bool{true};
    var active_layer = [_]bool{ true, true };
    var micro_topology = [_]@import("../soil/solute/transport.zig").Face{.{
        .first_cell = 0,
        .second_cell = 1,
        .water_flux_m3_per_step = 0,
    }};
    var macro_topology = micro_topology;
    var water = [_]f64{0.75};
    var zero = [_]f64{0};
    var heat = [_]f64{2.5};
    var faces: hydrology.SoilFaces = .{
        .allocator = std.testing.allocator,
        .direction_axis = &axes,
        .slot_source_cell = &slot_source,
        .slot_default_destination_cell = &slot_destination,
        .active_by_face = &active_face,
        .active_by_layer = &active_layer,
        .micropore_faces = &micro_topology,
        .macropore_faces = &macro_topology,
        .micropore_water_flux_m3_per_step = &water,
        .macropore_water_flux_m3_per_step = &zero,
        .vapor_flux_m3_per_step = &zero,
        .heat_flux_megajoules_per_step = &heat,
    };
    try accumulateSoilWaterHeatFaces(&ledger, &faces);
    const upper = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    const lower = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 });
    try std.testing.expectEqual(@as(f64, 0.75), ledger.activity[upper].water_output_m3);
    try std.testing.expectEqual(@as(f64, 0.75), ledger.activity[lower].water_input_m3);
    try std.testing.expectEqual(@as(f64, 2.5), ledger.activity[upper].heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 2.5), ledger.activity[lower].heat_input_megajoules);
}

test "horizontal water heat face is retained by layer scopes" {
    const layout = try Layout.init(2, 1, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    var axes = [_]u2{0};
    var slot_source = [_]usize{0};
    var slot_destination = [_]usize{1};
    var active_face = [_]bool{true};
    var active_layer = [_]bool{ true, true };
    var micro_topology = [_]@import("../soil/solute/transport.zig").Face{.{
        .first_cell = 0,
        .second_cell = 1,
        .water_flux_m3_per_step = 0,
    }};
    var macro_topology = micro_topology;
    var water = [_]f64{0.25};
    var zero = [_]f64{0};
    var heat = [_]f64{1.5};
    var faces: hydrology.SoilFaces = .{
        .allocator = std.testing.allocator,
        .direction_axis = &axes,
        .slot_source_cell = &slot_source,
        .slot_default_destination_cell = &slot_destination,
        .active_by_face = &active_face,
        .active_by_layer = &active_layer,
        .micropore_faces = &micro_topology,
        .macropore_faces = &macro_topology,
        .micropore_water_flux_m3_per_step = &water,
        .macropore_water_flux_m3_per_step = &zero,
        .vapor_flux_m3_per_step = &zero,
        .heat_flux_megajoules_per_step = &heat,
    };
    try accumulateSoilWaterHeatFaces(&ledger, &faces);
    const first = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    const second = try layout.index(.{ .kind = .soil_layer, .cell = 1, .layer = 0 });
    try std.testing.expectEqual(@as(f64, 0.25), ledger.activity[first].water_output_m3);
    try std.testing.expectEqual(@as(f64, 0.25), ledger.activity[second].water_input_m3);
    try std.testing.expectEqual(@as(f64, 1.5), ledger.activity[first].heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 1.5), ledger.activity[second].heat_input_megajoules);
}

test "aqueous face formula closes sulfur without aggregate ion cancellation" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    var axes = [_]u2{2};
    var slot_source = [_]usize{0};
    var slot_destination = [_]usize{1};
    var active_face = [_]bool{true};
    var active_layer = [_]bool{ true, true };
    var micro_topology = [_]@import("../soil/solute/transport.zig").Face{.{
        .first_cell = 0,
        .second_cell = 1,
        .water_flux_m3_per_step = 0,
    }};
    var macro_topology = micro_topology;
    var zero_face = [_]f64{0};
    var faces: hydrology.SoilFaces = .{
        .allocator = std.testing.allocator,
        .direction_axis = &axes,
        .slot_source_cell = &slot_source,
        .slot_default_destination_cell = &slot_destination,
        .active_by_face = &active_face,
        .active_by_layer = &active_layer,
        .micropore_faces = &micro_topology,
        .macropore_faces = &macro_topology,
        .micropore_water_flux_m3_per_step = &zero_face,
        .macropore_water_flux_m3_per_step = &zero_face,
        .vapor_flux_m3_per_step = &zero_face,
        .heat_flux_megajoules_per_step = &zero_face,
    };
    var micro_flux = [_]f64{0} ** solute_species.AqueousSpecies.count;
    var macro_flux = [_]f64{0} ** solute_species.AqueousSpecies.count;
    micro_flux[@intFromEnum(solute_species.AqueousSpecies.sulfate)] = 2;
    micro_flux[@intFromEnum(solute_species.AqueousSpecies.calcium_sulfate)] = -1;
    try accumulateAqueousFaces(&ledger, &faces, &micro_flux, &macro_flux, 12, 31);
    const upper = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    const lower = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 });
    try std.testing.expectEqual(@as(f64, 2), ledger.activity[upper].sulfur_output_mol);
    try std.testing.expectEqual(@as(f64, 2), ledger.activity[lower].sulfur_input_mol);
    try std.testing.expectEqual(@as(f64, 1), ledger.activity[upper].sulfur_input_mol);
    try std.testing.expectEqual(@as(f64, 1), ledger.activity[lower].sulfur_output_mol);
}

test "accepted soil external producers close independently at their owning layer" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    const active = [_]bool{ true, true };
    const water = [_]f64{ 1.5, 0 };
    const heat = [_]f64{ -2, 0 };
    var aqueous = [_]f64{0} ** (2 * solute_species.AqueousSpecies.count);
    aqueous[@intFromEnum(solute_species.AqueousSpecies.sulfate)] = 2;
    aqueous[@intFromEnum(solute_species.AqueousSpecies.calcium_sulfate)] = -1;
    var organic = [_]f64{0} ** (2 * organic_transport.component_count);
    organic[0] = 3;
    organic[1] = -4;
    organic[2] = 5;
    organic[3] = -6;
    const mineral = [_]f64{ 7, 0 };
    var dissolved_gas = [_]f64{0} ** (2 * gas_transport.species_count);
    dissolved_gas[@intFromEnum(gas_transport.Species.carbon_dioxide)] = 8;
    dissolved_gas[@intFromEnum(gas_transport.Species.methane)] = -9;
    dissolved_gas[@intFromEnum(gas_transport.Species.oxygen)] = 10;
    dissolved_gas[@intFromEnum(gas_transport.Species.nitrogen)] = -11;
    dissolved_gas[@intFromEnum(gas_transport.Species.nitrous_oxide)] = 12;
    dissolved_gas[@intFromEnum(gas_transport.Species.hydrogen)] = -13;
    try accumulateSoilExternalBoundaries(&ledger, .{
        .active_by_layer = &active,
        .boundary_water_gain_m3 = &water,
        .boundary_heat_gain_megajoules = &heat,
        .aqueous_boundary_net_input_mol = &aqueous,
        .organic_boundary_net_input_g = &organic,
        .mineral_nitrogen_boundary_export_g = &mineral,
        .dissolved_gas_boundary_net_input_g = &dissolved_gas,
        .carbon_g_per_mol = 12,
        .phosphorus_g_per_mol = 31,
    });

    const soil = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    try std.testing.expectEqual(@as(f64, 1.5), ledger.activity[soil].water_input_m3);
    try std.testing.expectEqual(@as(f64, 2), ledger.activity[soil].heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 11), ledger.activity[soil].carbon_input_g);
    try std.testing.expectEqual(@as(f64, 15), ledger.activity[soil].carbon_output_g);
    try std.testing.expectEqual(@as(f64, 12), ledger.activity[soil].nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 22), ledger.activity[soil].nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 5), ledger.activity[soil].phosphorus_input_g);
    try std.testing.expectEqual(@as(f64, 10), ledger.activity[soil].oxygen_input_g);
    try std.testing.expectEqual(@as(f64, 13), ledger.activity[soil].hydrogen_output_g);
    try std.testing.expectEqual(@as(f64, 2), ledger.activity[soil].sulfur_input_mol);
    try std.testing.expectEqual(@as(f64, 1), ledger.activity[soil].sulfur_output_mol);
    try std.testing.expectEqual(@as(f64, 1), ledger.activity[soil].calcium_output_mol);

    const scope_count = try layout.scopeCount();
    const before = try std.testing.allocator.alloc(inventory.Storage, scope_count);
    defer std.testing.allocator.free(before);
    const after = try std.testing.allocator.alloc(inventory.Storage, scope_count);
    defer std.testing.allocator.free(after);
    const area = try std.testing.allocator.alloc(f64, scope_count);
    defer std.testing.allocator.free(area);
    @memset(before, .{});
    @memset(after, .{});
    @memset(area, 1);
    before[soil] = .{
        .water_m3 = 100,
        .heat_megajoules = 100,
        .oxygen_g = 100,
        .hydrogen_g = 100,
        .residue_carbon_g = 100,
        .residue_nitrogen_g = 100,
        .residue_phosphorus_g = 100,
        .calcium_mol = 100,
        .sulfur_mol = 100,
    };
    after[soil] = .{
        .water_m3 = 101.5,
        .heat_megajoules = 98,
        .oxygen_g = 110,
        .hydrogen_g = 87,
        .residue_carbon_g = 96,
        .residue_nitrogen_g = 90,
        .residue_phosphorus_g = 105,
        .calcium_mol = 99,
        .sulfur_mol = 101,
    };
    var report = try evaluate(
        std.testing.allocator,
        before,
        after,
        ledger.activity,
        area,
        .{
            .absolute_per_area = .{
                .water_m = 1e-12,
                .heat_megajoules_m2 = 1e-12,
                .oxygen_g_m2 = 1e-12,
                .hydrogen_g_m2 = 1e-12,
                .carbon_g_m2 = 1e-12,
                .nitrogen_g_m2 = 1e-12,
                .phosphorus_g_m2 = 1e-12,
                .ions_mol_m2 = 1e-12,
            },
            .relative = 1e-10,
        },
    );
    defer report.deinit(std.testing.allocator);
    try requireAccepted(report);
}

test "soil external publication rejects inactive activity atomically" {
    const layout = try Layout.init(1, 1, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    const surface = try layout.index(.{ .kind = .surface, .cell = 0 });
    ledger.activity[surface].carbon_input_g = 3;
    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    const inactive = [_]bool{false};
    const water = [_]f64{1};
    const zero = [_]f64{0};
    const aqueous = [_]f64{0} ** solute_species.AqueousSpecies.count;
    const organic = [_]f64{0} ** organic_transport.component_count;
    const gas = [_]f64{0} ** gas_transport.species_count;
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulateSoilExternalBoundaries(&ledger, .{
            .active_by_layer = &inactive,
            .boundary_water_gain_m3 = &water,
            .boundary_heat_gain_megajoules = &zero,
            .aqueous_boundary_net_input_mol = &aqueous,
            .organic_boundary_net_input_g = &organic,
            .mineral_nitrogen_boundary_export_g = &zero,
            .dissolved_gas_boundary_net_input_g = &gas,
            .carbon_g_per_mol = 12,
            .phosphorus_g_per_mol = 31,
        }),
    );
    try std.testing.expectEqualDeep(before, ledger.activity);
}

test "dry gas boundaries retain exact layer surface and direction provenance" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    var soil_atmospheric = [_]f64{0} ** (2 * gas_transport.species_count);
    var soil_subsurface = [_]f64{0} ** (2 * gas_transport.species_count);
    var litter_atmospheric = [_]f64{0} ** gas_transport.species_count;
    soil_atmospheric[@intFromEnum(gas_transport.Species.carbon_dioxide)] = 2;
    soil_subsurface[@intFromEnum(gas_transport.Species.methane)] = -3;
    litter_atmospheric[@intFromEnum(gas_transport.Species.oxygen)] = 4;
    litter_atmospheric[@intFromEnum(gas_transport.Species.ammonia)] = -5;
    litter_atmospheric[@intFromEnum(gas_transport.Species.hydrogen)] = 6;
    try accumulateSoilSurfaceGasAtmosphere(
        &ledger,
        &.{1},
        &soil_atmospheric,
        &soil_subsurface,
        &litter_atmospheric,
    );
    const topsoil = ledger.activity[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 })];
    const inactive = ledger.activity[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 })];
    const surface = ledger.activity[try layout.index(.{ .kind = .surface, .cell = 0 })];
    try std.testing.expectEqual(@as(f64, 2), topsoil.carbon_input_g);
    try std.testing.expectEqual(@as(f64, 3), topsoil.carbon_output_g);
    try std.testing.expectEqualDeep(hourly.BoundaryActivity{}, inactive);
    try std.testing.expectEqual(@as(f64, 4), surface.oxygen_input_g);
    try std.testing.expectEqual(@as(f64, 5), surface.nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 6), surface.hydrogen_input_g);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    soil_atmospheric[gas_transport.species_count + @intFromEnum(gas_transport.Species.oxygen)] = 1;
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulateSoilSurfaceGasAtmosphere(
            &ledger,
            &.{1},
            &soil_atmospheric,
            &soil_subsurface,
            &litter_atmospheric,
        ),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "biogeochemical microbial mixing retains exact local CNP direction" {
    const layout = try Layout.init(1, 3, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    const soil_activity = [_]soil_microbial_mixing.SignedElementTransfer{
        .{ .carbon_g_c = 4, .nitrogen_g_n = 2, .phosphorus_g_p = 1 },
        .{ .carbon_g_c = -3, .nitrogen_g_n = -1.5, .phosphorus_g_p = -0.75 },
        .{},
    };
    try accumulateSoilMicrobialMixingActivity(&ledger, &.{3}, &.{0}, &soil_activity);
    const top = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    const middle = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 });
    const bottom = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 2 });
    try std.testing.expectEqual(@as(f64, 4), ledger.activity[top].carbon_output_g);
    // The middle layer receives four from above and three from below; keeping
    // both as inputs preserves direction and throughput instead of netting.
    try std.testing.expectEqual(@as(f64, 7), ledger.activity[middle].carbon_input_g);
    try std.testing.expectEqual(@as(f64, 3), ledger.activity[bottom].carbon_output_g);
    try std.testing.expectEqual(@as(f64, 0), ledger.activity[middle].carbon_output_g);

    const surface_activity = [_]surface_microbial_mixing.SignedElementTransfer{
        .{ .carbon_g_c = -5, .nitrogen_g_n = -2, .phosphorus_g_p = -1 },
    };
    try accumulateSurfaceTopsoilMicrobialMixingActivity(&ledger, &.{3}, &.{0}, &surface_activity);
    const surface = try layout.index(.{ .kind = .surface, .cell = 0 });
    try std.testing.expectEqual(@as(f64, 5), ledger.activity[top].carbon_output_g - 4);
    try std.testing.expectEqual(@as(f64, 5), ledger.activity[surface].carbon_input_g);
}

test "biogeochemical mixing rejects mixed element directions atomically" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    ledger.activity[0].carbon_input_g = 7;
    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    const invalid = [_]soil_microbial_mixing.SignedElementTransfer{
        .{ .carbon_g_c = 1, .nitrogen_g_n = -1 },
        .{},
    };
    try std.testing.expectError(
        error.InvalidLayerConservationTransfer,
        accumulateSoilMicrobialMixingActivity(&ledger, &.{2}, &.{0}, &invalid),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "biogeochemical reactions retain exact soil layer and surface provenance" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();

    var soil_oxygen = try soil_oxygen_allocation.State.init(std.testing.allocator, 1, 2, 2);
    defer soil_oxygen.deinit();
    var soil_products = try soil_respiration_products.State.init(std.testing.allocator, 2, 2);
    defer soil_products.deinit();
    var soil_methane_state = try soil_methane.State.init(std.testing.allocator, 2);
    defer soil_methane_state.deinit();
    soil_oxygen.oxygen_uptake_g_o[0] = 1;
    soil_oxygen.oxygen_uptake_g_o[1] = 2;
    soil_products.hydrogen_g_h[0] = 4;
    soil_products.hydrogen_g_h[1] = 5;
    soil_methane_state.hydrogen_consumption_g_h[0] = 6;
    try accumulateSoilBiogeochemicalReactions(
        &ledger,
        &.{1},
        &.{0},
        &soil_oxygen,
        &soil_products,
        &soil_methane_state,
    );
    const topsoil = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    try std.testing.expectEqual(@as(f64, 3), ledger.activity[topsoil].oxygen_internal_consumption_g);
    try std.testing.expectEqual(@as(f64, 9), ledger.activity[topsoil].hydrogen_internal_production_g);
    try std.testing.expectEqual(@as(f64, 6), ledger.activity[topsoil].hydrogen_internal_consumption_g);

    var surface_oxygen_state = try surface_oxygen.State.init(std.testing.allocator, 1);
    defer surface_oxygen_state.deinit();
    var surface_autotrophic_state = try surface_autotrophic.State.init(std.testing.allocator, 1);
    defer surface_autotrophic_state.deinit();
    surface_oxygen_state.allocation.oxygen_uptake_g_o[0] = 7;
    surface_oxygen_state.allocation.oxygen_uptake_g_o[1] = 8;
    surface_oxygen_state.respiration_hydrogen_g_h_per_step[0] = 10;
    surface_autotrophic_state.actual_primary_reaction[3] = 11;
    try accumulateSurfaceBiogeochemicalReactions(
        &ledger,
        &.{0},
        &surface_oxygen_state,
        &surface_autotrophic_state,
    );
    const surface = try layout.index(.{ .kind = .surface, .cell = 0 });
    try std.testing.expectEqual(@as(f64, 15), ledger.activity[surface].oxygen_internal_consumption_g);
    try std.testing.expectEqual(@as(f64, 10), ledger.activity[surface].hydrogen_internal_production_g);
    try std.testing.expectEqual(@as(f64, 11), ledger.activity[surface].hydrogen_internal_consumption_g);
}

test "surface biogeochemistry retains four exact topsoil transfer paths" {
    const layout = try Layout.init(1, 1, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    var decomposition = try surface_organic_decomposition.State.init(std.testing.allocator, 1);
    defer decomposition.deinit();
    var turnover = try surface_microbial_turnover.State.init(std.testing.allocator, 1);
    defer turnover.deinit();
    var heterotrophic_exchange = try surface_topsoil_exchange.State.init(std.testing.allocator, 1);
    defer heterotrophic_exchange.deinit();
    var autotrophic = try surface_autotrophic.State.init(std.testing.allocator, 1);
    defer autotrophic.deinit();

    heterotrophic_exchange.ammonium_exchange_g_n[0] = 2;
    heterotrophic_exchange.h2po4_exchange_g_p[0] = 3;
    decomposition.particulate_products[0] = .{ .carbon_g_c = 4, .nitrogen_g_n = 5, .phosphorus_g_p = 6 };
    turnover.basal[0].humified = .{ .carbon_g_c = 7, .nitrogen_g_n = 8, .phosphorus_g_p = 9 };
    autotrophic.topsoil_ammonium_exchange_g_n[0] = 10;
    autotrophic.topsoil_hpo4_exchange_g_p[0] = 11;
    var accepted_autotrophic_topsoil_organic = [_]organic_state.ElementPool{.{}} ** surface_autotrophic.active_population_count;
    accepted_autotrophic_topsoil_organic[0] = .{ .carbon_g_c = 12, .nitrogen_g_n = 13, .phosphorus_g_p = 14 };
    try accumulateSurfaceBiogeochemicalActivity(
        &ledger,
        &.{1},
        &.{0},
        &decomposition,
        &turnover,
        &heterotrophic_exchange,
        &autotrophic,
        &accepted_autotrophic_topsoil_organic,
    );
    const surface = try layout.index(.{ .kind = .surface, .cell = 0 });
    const topsoil = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    try std.testing.expectEqual(@as(f64, 12), ledger.activity[topsoil].nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 14), ledger.activity[topsoil].phosphorus_output_g);
    try std.testing.expectEqual(@as(f64, 12), ledger.activity[surface].nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 14), ledger.activity[surface].phosphorus_input_g);
    try std.testing.expectEqual(@as(f64, 23), ledger.activity[surface].carbon_output_g);
    try std.testing.expectEqual(@as(f64, 26), ledger.activity[surface].nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 29), ledger.activity[surface].phosphorus_output_g);
    try std.testing.expectEqual(@as(f64, 23), ledger.activity[topsoil].carbon_input_g);
    try std.testing.expectEqual(@as(f64, 26), ledger.activity[topsoil].nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 29), ledger.activity[topsoil].phosphorus_input_g);
}

test "surface organic heat rebase retains signed local activity atomically" {
    const layout = try Layout.init(2, 1, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    try accumulateSurfaceOrganicHeatRebase(&ledger, &.{ 4, -3 });
    const first = try layout.index(.{ .kind = .surface, .cell = 0 });
    const second = try layout.index(.{ .kind = .surface, .cell = 1 });
    try std.testing.expectEqual(@as(f64, 4), ledger.activity[first].heat_internal_production_megajoules);
    try std.testing.expectEqual(@as(f64, 3), ledger.activity[second].heat_internal_consumption_megajoules);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(
        error.InvalidLayerConservationActivity,
        accumulateSurfaceOrganicHeatRebase(&ledger, &.{ 1, std.math.nan(f64) }),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "soil layer signed internal heat preserves scope and direction" {
    const layout = try Layout.init(2, 3, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();

    try accumulateSoilLayerSignedInternalHeat(
        &ledger,
        &.{ 2, 1 },
        &.{ 4, -3, 0, -5, 0, 0 },
    );

    const first_upper = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    const first_lower = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 });
    const second_top = try layout.index(.{ .kind = .soil_layer, .cell = 1, .layer = 0 });
    try std.testing.expectEqual(@as(f64, 4), ledger.activity[first_upper].heat_internal_production_megajoules);
    try std.testing.expectEqual(@as(f64, 3), ledger.activity[first_lower].heat_internal_consumption_megajoules);
    try std.testing.expectEqual(@as(f64, 5), ledger.activity[second_top].heat_internal_consumption_megajoules);

    const first_inactive = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 2 });
    const second_inactive = try layout.index(.{ .kind = .soil_layer, .cell = 1, .layer = 1 });
    try std.testing.expectEqualDeep(hourly.BoundaryActivity{}, ledger.activity[first_inactive]);
    try std.testing.expectEqualDeep(hourly.BoundaryActivity{}, ledger.activity[second_inactive]);
}

test "soil layer signed internal heat rejects malformed activity atomically" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    try accumulateSoilLayerSignedInternalHeat(&ledger, &.{2}, &.{ 7, -2 });

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(
        error.LayerConservationActivityDimensionMismatch,
        accumulateSoilLayerSignedInternalHeat(&ledger, &.{2}, &.{7}),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
    try std.testing.expectError(
        error.InvalidLayerConservationActivity,
        accumulateSoilLayerSignedInternalHeat(&ledger, &.{2}, &.{ std.math.nan(f64), 0 }),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulateSoilLayerSignedInternalHeat(&ledger, &.{1}, &.{ 0, -1 }),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "litter soil interface publishes both gross directions only to local scopes" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    try accumulateLitterSoilInterfaceActivity(
        &ledger,
        &.{2},
        &.{.{
            .water_m3 = 2,
            .heat_megajoules = 3,
            .carbon_g = 5,
            .nitrogen_g = 7,
            .phosphorus_g = 11,
            .calcium_mol = 13,
        }},
        &.{.{
            .water_m3 = 17,
            .heat_megajoules = 19,
            .carbon_g = 23,
            .nitrogen_g = 29,
            .phosphorus_g = 31,
            .calcium_mol = 37,
        }},
    );
    const topsoil = ledger.activity[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 })];
    const lower = ledger.activity[try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 })];
    const surface = ledger.activity[try layout.index(.{ .kind = .surface, .cell = 0 })];
    try std.testing.expectEqual(@as(f64, 2), surface.water_output_m3);
    try std.testing.expectEqual(@as(f64, 17), surface.water_input_m3);
    try std.testing.expectEqual(@as(f64, 3), topsoil.heat_input_megajoules);
    try std.testing.expectEqual(@as(f64, 19), topsoil.heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 5), surface.carbon_output_g);
    try std.testing.expectEqual(@as(f64, 23), surface.carbon_input_g);
    try std.testing.expectEqual(@as(f64, 13), topsoil.calcium_input_mol);
    try std.testing.expectEqual(@as(f64, 37), topsoil.calcium_output_mol);
    try std.testing.expectEqualDeep(hourly.BoundaryActivity{}, lower);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulateLitterSoilInterfaceActivity(
            &ledger,
            &.{0},
            &.{.{ .water_m3 = 1 }},
            &.{.{}},
        ),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "surface topsoil heat transfer books equal and opposite local scopes atomically" {
    const layout = try Layout.init(2, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    try accumulateSurfaceTopsoilHeatTransfer(
        &ledger,
        &.{ 2, 1 },
        &.{ 4, 0, -3, 0 },
    );

    const surface0 = try layout.index(.{ .kind = .surface, .cell = 0 });
    const soil0 = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    const surface1 = try layout.index(.{ .kind = .surface, .cell = 1 });
    const soil1 = try layout.index(.{ .kind = .soil_layer, .cell = 1, .layer = 0 });
    try std.testing.expectEqual(@as(f64, 4), ledger.activity[surface0].heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 4), ledger.activity[soil0].heat_input_megajoules);
    try std.testing.expectEqual(@as(f64, 3), ledger.activity[soil1].heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 3), ledger.activity[surface1].heat_input_megajoules);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(
        error.InvalidLayerConservationActivity,
        accumulateSurfaceTopsoilHeatTransfer(&ledger, &.{ 2, 1 }, &.{ 0, 1, 0, 0 }),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "soil external advective heat preserves outward and inward layer throughput" {
    const layout = try Layout.init(1, 3, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    try accumulateSoilExternalAdvectiveHeat(
        &ledger,
        &.{ true, true, false },
        &.{ 4, -3, 0 },
    );
    const first = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    const second = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 });
    try std.testing.expectEqual(@as(f64, 4), ledger.activity[first].heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 3), ledger.activity[second].heat_input_megajoules);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulateSoilExternalAdvectiveHeat(
            &ledger,
            &.{ true, true, false },
            &.{ 0, 0, 1 },
        ),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "surface endpoint reference heat reaches exact local surface scopes" {
    const layout = try Layout.init(2, 1, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    try accumulateSurfaceEndpointReferenceHeat(
        &ledger,
        &.{ 0.1, -0.2 },
        &.{ 0.01, -0.02 },
        4.19,
        1.9274 / 0.917,
        273.15,
        2465,
    );
    const first = try layout.index(.{ .kind = .surface, .cell = 0 });
    const second = try layout.index(.{ .kind = .surface, .cell = 1 });
    const expected_first = try hourly.surfaceEndpointReferenceHeatMegajoules(
        0.1,
        0.01,
        4.19,
        1.9274 / 0.917,
        273.15,
        2465,
    );
    const expected_second = try hourly.surfaceEndpointReferenceHeatMegajoules(
        -0.2,
        -0.02,
        4.19,
        1.9274 / 0.917,
        273.15,
        2465,
    );
    try std.testing.expectApproxEqAbs(
        expected_first,
        ledger.activity[first].heat_internal_production_megajoules,
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        -expected_second,
        ledger.activity[second].heat_internal_consumption_megajoules,
        1e-12,
    );
}

test "all dedicated face transports retain layer and element provenance" {
    const layout = try Layout.init(1, 2, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    var axes = [_]u2{2};
    var slot_source = [_]usize{0};
    var slot_destination = [_]usize{1};
    var active_face = [_]bool{true};
    var active_layer = [_]bool{ true, true };
    var micro_topology = [_]@import("../soil/solute/transport.zig").Face{.{
        .first_cell = 0,
        .second_cell = 1,
        .water_flux_m3_per_step = 0,
    }};
    var macro_topology = micro_topology;
    var zero_face = [_]f64{0};
    var faces: hydrology.SoilFaces = .{
        .allocator = std.testing.allocator,
        .direction_axis = &axes,
        .slot_source_cell = &slot_source,
        .slot_default_destination_cell = &slot_destination,
        .active_by_face = &active_face,
        .active_by_layer = &active_layer,
        .micropore_faces = &micro_topology,
        .macropore_faces = &macro_topology,
        .micropore_water_flux_m3_per_step = &zero_face,
        .macropore_water_flux_m3_per_step = &zero_face,
        .vapor_flux_m3_per_step = &zero_face,
        .heat_flux_megajoules_per_step = &zero_face,
    };

    var gas_state: gas_transport_step.State = undefined;
    var gas_faces = [_]gas_transport.Face{.{ .first_cell = 0, .second_cell = 1 }};
    var gas_flux = [_]f64{0} ** gas_transport.species_count;
    gas_flux[@intFromEnum(gas_transport.Species.oxygen)] = 3;
    gas_state.accepted_faces = &gas_faces;
    gas_state.accepted_face_flux_g_per_h = &gas_flux;
    try accumulateGasFaces(&ledger, &gas_state);

    var dissolved_micro = [_]f64{0} ** gas_transport.species_count;
    var dissolved_macro = [_]f64{0} ** gas_transport.species_count;
    dissolved_micro[@intFromEnum(gas_transport.Species.hydrogen)] = 2;
    dissolved_micro[@intFromEnum(gas_transport.Species.ammonia)] = 99;
    try accumulateDissolvedGasFaces(&ledger, &faces, &dissolved_micro, &dissolved_macro);

    var organic_micro = [_]f64{0} ** organic_transport.component_count;
    var organic_macro = [_]f64{0} ** organic_transport.component_count;
    organic_micro[0] = 4;
    try accumulateOrganicFaces(&ledger, &faces, &organic_micro, &organic_macro);

    var mineral_micro = [_]f64{0} ** mineral_nitrogen_transport.species_count;
    var mineral_macro = [_]f64{0} ** mineral_nitrogen_transport.species_count;
    mineral_micro[0] = 0.5;
    try accumulateMineralNitrogenFaces(&ledger, &faces, &mineral_micro, &mineral_macro, 14);

    const upper = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    const lower = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 });
    try std.testing.expectEqual(@as(f64, 3), ledger.activity[upper].oxygen_output_g);
    try std.testing.expectEqual(@as(f64, 3), ledger.activity[lower].oxygen_input_g);
    try std.testing.expectEqual(@as(f64, 2), ledger.activity[upper].hydrogen_output_g);
    try std.testing.expectEqual(@as(f64, 2), ledger.activity[lower].hydrogen_input_g);
    try std.testing.expectEqual(@as(f64, 4), ledger.activity[upper].carbon_output_g);
    try std.testing.expectEqual(@as(f64, 4), ledger.activity[lower].carbon_input_g);
    try std.testing.expectEqual(@as(f64, 7), ledger.activity[upper].nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 7), ledger.activity[lower].nitrogen_input_g);
}

test "soil gas bubbling publishes exact nonlocal source and receiver legs atomically" {
    const layout = try Layout.init(1, 3, 1);
    var ledger = try Ledger.init(std.testing.allocator, layout);
    defer ledger.deinit();
    const input = [_]hourly.IntercellTransfer{
        .{ .oxygen_g = 5, .hydrogen_g = 0.5, .carbon_g = 3, .nitrogen_g = 7 },
        .{},
        .{},
    };
    const output = [_]hourly.IntercellTransfer{
        .{},
        .{ .oxygen_g = 2, .hydrogen_g = 0.2, .carbon_g = 1, .nitrogen_g = 4 },
        .{ .oxygen_g = 3, .hydrogen_g = 0.3, .carbon_g = 2, .nitrogen_g = 3 },
    };
    try accumulateSoilGasBubbleActivity(&ledger, &.{3}, &input, &output);
    const receiver = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    const first_source = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 1 });
    const second_source = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 2 });
    try std.testing.expectEqual(@as(f64, 5), ledger.activity[receiver].oxygen_input_g);
    try std.testing.expectEqual(@as(f64, 0.5), ledger.activity[receiver].hydrogen_input_g);
    try std.testing.expectEqual(@as(f64, 3), ledger.activity[receiver].carbon_input_g);
    try std.testing.expectEqual(@as(f64, 7), ledger.activity[receiver].nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 2), ledger.activity[first_source].oxygen_output_g);
    try std.testing.expectEqual(@as(f64, 3), ledger.activity[second_source].oxygen_output_g);

    const before = try std.testing.allocator.dupe(hourly.BoundaryActivity, ledger.activity);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(
        error.InactiveLayerConservationActivity,
        accumulateSoilGasBubbleActivity(&ledger, &.{2}, &input, &output),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, before, ledger.activity);
}

test "accumulated layer gate rejects same sign leaks and preserves prior state" {
    const layout = try Layout.init(1, 1, 1);
    const scope_count = try layout.scopeCount();
    var slot: ?AccumulatedState = null;
    defer if (slot) |*state| state.deinit();
    const initial = try std.testing.allocator.alloc(inventory.Storage, scope_count);
    defer std.testing.allocator.free(initial);
    const first = try std.testing.allocator.alloc(inventory.Storage, scope_count);
    defer std.testing.allocator.free(first);
    const second = try std.testing.allocator.alloc(inventory.Storage, scope_count);
    defer std.testing.allocator.free(second);
    const activity = try std.testing.allocator.alloc(hourly.BoundaryActivity, scope_count);
    defer std.testing.allocator.free(activity);
    const area = try std.testing.allocator.alloc(f64, scope_count);
    defer std.testing.allocator.free(area);
    @memset(initial, .{});
    @memset(first, .{});
    @memset(second, .{});
    @memset(activity, .{});
    @memset(area, 1);
    const soil = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    initial[soil].water_m3 = 10;
    first[soil].water_m3 = 10.0006;
    second[soil].water_m3 = 10.0012;
    const tolerances: hourly.Tolerances = .{
        .absolute_per_area = .{ .water_m = 1e-3 },
        .relative = 1e-12,
    };
    var first_report = try evaluateAndCommitAccumulated(
        &slot,
        std.testing.allocator,
        std.testing.allocator,
        layout,
        initial,
        first,
        activity,
        area,
        tolerances,
        0,
    );
    first_report.deinit(std.testing.allocator);
    const snapshot = try slot.?.clone(std.testing.allocator);
    defer @constCast(&snapshot).deinit();
    try std.testing.expectError(
        error.AccumulatedLayerConservationFailure,
        evaluateAndCommitAccumulated(
            &slot,
            std.testing.allocator,
            std.testing.allocator,
            layout,
            first,
            second,
            activity,
            area,
            tolerances,
            1,
        ),
    );
    try std.testing.expectEqual(snapshot.accepted_hour_count, slot.?.accepted_hour_count);
    try std.testing.expectEqualDeep(snapshot.latest_storage, slot.?.latest_storage);
    try std.testing.expectEqualDeep(snapshot.cumulative_activity, slot.?.cumulative_activity);
}

const std = @import("std");

/// Persistent suspended-particulate ownership.  The fixed leading families
/// correspond to REDIST's mineral carriers; runtime-sized trailing families
/// retain every translated organic, fertilizer and solid-chemistry pool.
///
/// Chemistry components are conserved particulate amounts while suspended.
/// A bridge combines each live concentration owner with its explicit pending
/// owner before detachment, and chooses live or pending ownership from the
/// receiving carrier only after deposition.  Keeping two artificial species
/// in suspension would make the result depend on the donor carrier state.
pub const Family = enum {
    mineral_texture,
    exchange_capacity,
    organic_cnp,
    nitrogen_fertilizer,
    dry_mineral_fertilizer,
    chemistry_live_and_pending,
};

pub const Range = struct {
    start: usize,
    len: usize,

    pub fn end(self: Range) usize {
        return self.start + self.len;
    }
};

pub const Layout = struct {
    organic_cnp_count: usize,
    nitrogen_fertilizer_count: usize,
    dry_mineral_fertilizer_count: usize,
    chemistry_live_and_pending_count: usize,

    pub const mineral_texture_count: usize = 3; // sand, silt, clay (Mg)
    pub const exchange_capacity_count: usize = 2; // CEC, AEC (mol)
    pub fn validate(self: Layout) !void {
        inline for (.{
            self.organic_cnp_count,
            self.nitrogen_fertilizer_count,
            self.dry_mineral_fertilizer_count,
            self.chemistry_live_and_pending_count,
        }) |count| if (count == 0) return error.EmptySuspendedConstituentFamily;
        _ = try self.componentCount();
    }

    pub fn componentCount(self: Layout) !usize {
        var count: usize = mineral_texture_count + exchange_capacity_count;
        count = try std.math.add(usize, count, self.organic_cnp_count);
        count = try std.math.add(usize, count, self.nitrogen_fertilizer_count);
        count = try std.math.add(usize, count, self.dry_mineral_fertilizer_count);
        return std.math.add(usize, count, self.chemistry_live_and_pending_count);
    }

    pub fn range(self: Layout, family: Family) !Range {
        try self.validate();
        const texture = Range{ .start = 0, .len = mineral_texture_count };
        const exchange = Range{ .start = texture.end(), .len = exchange_capacity_count };
        // Reference erosion.f:542-555,768-781 routes exactly sand, silt,
        // clay, CEC and AEC. ROCK participates only in internal REDIST layer
        // movement (redist.f:9605-9607), so it must not be suspended here.
        const organic = Range{ .start = exchange.end(), .len = self.organic_cnp_count };
        const nitrogen_fertilizer = Range{ .start = organic.end(), .len = self.nitrogen_fertilizer_count };
        const dry_mineral_fertilizer = Range{ .start = nitrogen_fertilizer.end(), .len = self.dry_mineral_fertilizer_count };
        const chemistry = Range{ .start = dry_mineral_fertilizer.end(), .len = self.chemistry_live_and_pending_count };
        return switch (family) {
            .mineral_texture => texture,
            .exchange_capacity => exchange,
            .organic_cnp => organic,
            .nitrogen_fertilizer => nitrogen_fertilizer,
            .dry_mineral_fertilizer => dry_mineral_fertilizer,
            .chemistry_live_and_pending => chemistry,
        };
    }
};

pub const DirectionalSediment = struct {
    east_megagrams: []const f64,
    west_megagrams: []const f64,
    south_megagrams: []const f64,
    north_megagrams: []const f64,
};

pub const DirectionalConstituentFlux = struct {
    east: []f64,
    west: []f64,
    south: []f64,
    north: []f64,
};

/// Checkpoints must serialize `layout` and `pools`, plus
/// `sediment_megagrams` exactly once through either this state or its borrowed
/// erosion owner. `exported`, local/settled transfers and directional fluxes
/// are accepted-hour diagnostics deliberately cleared by `restore`; scratch
/// storage is never serialized.
pub const checkpoint_schema_version: u16 = 1;

pub const State = struct {
    allocator: std.mem.Allocator,
    owns_sediment_storage: bool,
    cell_count: usize,
    component_count: usize,
    layout: Layout,
    sediment_megagrams: []f64,
    pools: []f64,
    exported: []f64,
    /// Signed donor-to-suspension transfer accepted by `exchangeLocal`.
    local_transfer_to_suspension: []f64,
    /// Runtime-local soil layer owning each accepted local exchange.  The
    /// packed component sidecar above is positive for soil->surface and
    /// negative for surface->soil; this index is published by the same atomic
    /// commit and therefore never describes a rejected attempt.
    local_exchange_soil_layer_by_cell: []usize,
    /// Signed carrier mass using the same soil->surface convention as
    /// `local_transfer_to_suspension` (Mg).
    local_sediment_to_suspension_megagrams: []f64,
    /// Positive suspension-to-topsoil transfer accepted by `settle`.
    settled_transfer_to_topsoil: []f64,
    flux: DirectionalConstituentFlux,

    scratch_sediment_megagrams: []f64,
    scratch_topsoil_mass_megagrams: []f64,
    scratch_pools: []f64,
    scratch_topsoil_pools: []f64,
    scratch_exported: []f64,
    scratch_transfer: []f64,
    scratch_flux: DirectionalConstituentFlux,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, layout: Layout) !State {
        if (cell_count == 0) return error.InvalidSuspendedConstituentDimensions;
        const sediment_megagrams = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(sediment_megagrams);
        @memset(sediment_megagrams, 0);
        return initWithStorage(allocator, sediment_megagrams, true, layout);
    }

    /// Shares the already-authoritative erosion scalar slice.  This is the
    /// production constructor while `erosion.RuntimeState` continues to own
    /// `surface_sediment_megagrams`; it prevents duplicate scalar state and
    /// intentionally leaves that borrowed allocation untouched by `deinit`.
    pub fn initBorrowingSediment(
        allocator: std.mem.Allocator,
        sediment_megagrams: []f64,
        layout: Layout,
    ) !State {
        return initWithStorage(allocator, sediment_megagrams, false, layout);
    }

    fn initWithStorage(
        allocator: std.mem.Allocator,
        sediment_megagrams: []f64,
        owns_sediment_storage: bool,
        layout: Layout,
    ) !State {
        const cell_count = sediment_megagrams.len;
        if (cell_count == 0) return error.InvalidSuspendedConstituentDimensions;
        try layout.validate();
        try validateNonnegativeFinite(sediment_megagrams);
        const component_count = try layout.componentCount();
        const packed_count = try std.math.mul(usize, cell_count, component_count);
        var result: State = undefined;
        result.allocator = allocator;
        result.owns_sediment_storage = owns_sediment_storage;
        result.cell_count = cell_count;
        result.component_count = component_count;
        result.layout = layout;
        result.sediment_megagrams = sediment_megagrams;
        result.scratch_sediment_megagrams = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.scratch_sediment_megagrams);
        result.scratch_topsoil_mass_megagrams = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.scratch_topsoil_mass_megagrams);
        result.pools = try allocator.alloc(f64, packed_count);
        errdefer allocator.free(result.pools);
        result.exported = try allocator.alloc(f64, packed_count);
        errdefer allocator.free(result.exported);
        result.local_transfer_to_suspension = try allocator.alloc(f64, packed_count);
        errdefer allocator.free(result.local_transfer_to_suspension);
        result.local_exchange_soil_layer_by_cell = try allocator.alloc(usize, cell_count);
        errdefer allocator.free(result.local_exchange_soil_layer_by_cell);
        result.local_sediment_to_suspension_megagrams = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.local_sediment_to_suspension_megagrams);
        result.settled_transfer_to_topsoil = try allocator.alloc(f64, packed_count);
        errdefer allocator.free(result.settled_transfer_to_topsoil);
        result.scratch_pools = try allocator.alloc(f64, packed_count);
        errdefer allocator.free(result.scratch_pools);
        result.scratch_topsoil_pools = try allocator.alloc(f64, packed_count);
        errdefer allocator.free(result.scratch_topsoil_pools);
        result.scratch_exported = try allocator.alloc(f64, packed_count);
        errdefer allocator.free(result.scratch_exported);
        result.scratch_transfer = try allocator.alloc(f64, packed_count);
        errdefer allocator.free(result.scratch_transfer);
        result.flux = try allocFlux(allocator, packed_count);
        errdefer freeFlux(allocator, result.flux);
        result.scratch_flux = try allocFlux(allocator, packed_count);
        inline for (.{
            result.scratch_sediment_megagrams,
            result.scratch_topsoil_mass_megagrams,
            result.pools,
            result.exported,
            result.local_transfer_to_suspension,
            result.settled_transfer_to_topsoil,
            result.scratch_pools,
            result.scratch_topsoil_pools,
            result.scratch_exported,
            result.scratch_transfer,
        }) |values| @memset(values, 0);
        @memset(result.local_exchange_soil_layer_by_cell, 0);
        @memset(result.local_sediment_to_suspension_megagrams, 0);
        return result;
    }

    pub fn deinit(self: *State) void {
        freeFlux(self.allocator, self.scratch_flux);
        freeFlux(self.allocator, self.flux);
        inline for (.{ "scratch_transfer", "scratch_exported", "scratch_topsoil_pools", "scratch_pools", "settled_transfer_to_topsoil", "local_transfer_to_suspension", "local_sediment_to_suspension_megagrams", "local_exchange_soil_layer_by_cell", "exported", "pools", "scratch_topsoil_mass_megagrams", "scratch_sediment_megagrams" }) |name|
            self.allocator.free(@field(self, name));
        if (self.owns_sediment_storage) self.allocator.free(self.sediment_megagrams);
        self.* = undefined;
    }

    pub fn familySlice(self: *State, cell: usize, family: Family) ![]f64 {
        if (cell >= self.cell_count) return error.InvalidSuspendedConstituentDimensions;
        const family_range = try self.layout.range(family);
        const first = try std.math.add(usize, try std.math.mul(usize, cell, self.component_count), family_range.start);
        return self.pools[first..][0..family_range.len];
    }

    /// Transactional checkpoint restore.  Failed validation leaves all
    /// persistent state and accepted diagnostics unchanged.
    pub fn restore(self: *State, sediment_megagrams: []const f64, pools: []const f64) !void {
        try self.validateDimensions(sediment_megagrams, pools);
        try validateNonnegativeFinite(sediment_megagrams);
        try validateNonnegativeFinite(pools);
        @memcpy(self.sediment_megagrams, sediment_megagrams);
        @memcpy(self.pools, pools);
        @memset(self.exported, 0);
        @memset(self.local_transfer_to_suspension, 0);
        @memset(self.local_exchange_soil_layer_by_cell, 0);
        @memset(self.local_sediment_to_suspension_megagrams, 0);
        @memset(self.settled_transfer_to_topsoil, 0);
        clearFlux(self.flux);
    }

    pub fn validate(self: *const State) !void {
        try self.layout.validate();
        if (self.component_count != try self.layout.componentCount() or
            self.sediment_megagrams.len != self.cell_count or
            self.scratch_sediment_megagrams.len != self.cell_count or
            self.scratch_topsoil_mass_megagrams.len != self.cell_count)
            return error.InvalidSuspendedConstituentDimensions;
        if (self.local_exchange_soil_layer_by_cell.len != self.cell_count or
            self.local_sediment_to_suspension_megagrams.len != self.cell_count)
            return error.InvalidSuspendedConstituentDimensions;
        const count = try std.math.mul(usize, self.cell_count, self.component_count);
        inline for (.{ self.pools, self.exported, self.local_transfer_to_suspension, self.settled_transfer_to_topsoil, self.scratch_pools, self.scratch_topsoil_pools, self.scratch_exported, self.scratch_transfer }) |values|
            if (values.len != count) return error.InvalidSuspendedConstituentDimensions;
        try validateFluxDimensions(self.flux, count);
        try validateFluxDimensions(self.scratch_flux, count);
        try validateNonnegativeFinite(self.sediment_megagrams);
        try validateNonnegativeFinite(self.pools);
        try validateNonnegativeFinite(self.exported);
        try validateFinite(self.local_transfer_to_suspension);
        try validateFinite(self.local_sediment_to_suspension_megagrams);
        try validateNonnegativeFinite(self.settled_transfer_to_topsoil);
    }

    fn validateDimensions(self: *const State, sediment_megagrams: []const f64, pools: []const f64) !void {
        if (sediment_megagrams.len != self.cell_count or
            pools.len != try std.math.mul(usize, self.cell_count, self.component_count))
            return error.InvalidSuspendedConstituentDimensions;
    }
};

/// Copies a bridge's cell-major family buffer into the comprehensive packed
/// topsoil buffer consumed by `exchangeLocal` and `settle`.  This keeps each
/// scientific owner responsible for its native units and stoichiometry while
/// the suspension state applies the one common sediment fraction.
pub fn packFamily(
    layout: Layout,
    cell_count: usize,
    family: Family,
    family_pools: []const f64,
    packed_topsoil_pools: []f64,
) !void {
    const component_count = try layout.componentCount();
    const family_range = try layout.range(family);
    if (cell_count == 0 or
        family_pools.len != try std.math.mul(usize, cell_count, family_range.len) or
        packed_topsoil_pools.len != try std.math.mul(usize, cell_count, component_count))
        return error.InvalidSuspendedConstituentDimensions;
    try validateNonnegativeFinite(family_pools);
    for (0..cell_count) |cell| {
        const destination = cell * component_count + family_range.start;
        const source = cell * family_range.len;
        @memcpy(
            packed_topsoil_pools[destination..][0..family_range.len],
            family_pools[source..][0..family_range.len],
        );
    }
}

/// Inverse of `packFamily`, used after an accepted exchange or settling
/// transaction to rematerialize each bridge's native live/pending owners.
pub fn unpackFamily(
    layout: Layout,
    cell_count: usize,
    family: Family,
    packed_topsoil_pools: []const f64,
    family_pools: []f64,
) !void {
    const component_count = try layout.componentCount();
    const family_range = try layout.range(family);
    if (cell_count == 0 or
        family_pools.len != try std.math.mul(usize, cell_count, family_range.len) or
        packed_topsoil_pools.len != try std.math.mul(usize, cell_count, component_count))
        return error.InvalidSuspendedConstituentDimensions;
    try validateNonnegativeFinite(packed_topsoil_pools);
    for (0..cell_count) |cell| {
        const source = cell * component_count + family_range.start;
        const destination = cell * family_range.len;
        @memcpy(
            family_pools[destination..][0..family_range.len],
            packed_topsoil_pools[source..][0..family_range.len],
        );
    }
}

/// Applies the signed local EROSION source before directional routing.
/// Positive values detach topsoil into suspension using the surface-soil
/// carrier; negative values deposit the same fraction of every currently
/// suspended constituent.  Donor loss and recipient gain are bit-identical.
pub fn exchangeLocal(
    state: *State,
    topsoil_mass_megagrams: []f64,
    topsoil_pools: []f64,
    net_detachment_megagrams: []const f64,
    topsoil_layer_by_cell: []const usize,
) !void {
    try state.validateDimensions(topsoil_mass_megagrams, topsoil_pools);
    if (net_detachment_megagrams.len != state.cell_count or
        topsoil_layer_by_cell.len != state.cell_count)
        return error.InvalidSuspendedConstituentDimensions;
    try state.validate();
    try validatePositiveFinite(topsoil_mass_megagrams);
    try validateNonnegativeFinite(topsoil_pools);
    try validateFinite(net_detachment_megagrams);

    @memcpy(state.scratch_sediment_megagrams, state.sediment_megagrams);
    @memcpy(state.scratch_topsoil_mass_megagrams, topsoil_mass_megagrams);
    @memcpy(state.scratch_pools, state.pools);
    @memcpy(state.scratch_topsoil_pools, topsoil_pools);
    @memset(state.scratch_transfer, 0);
    for (0..state.cell_count) |cell| {
        const change = net_detachment_megagrams[cell];
        const first = cell * state.component_count;
        if (change >= 0) {
            if (change > topsoil_mass_megagrams[cell]) return error.LocalDetachmentExceedsTopsoilCarrier;
            const fraction = change / topsoil_mass_megagrams[cell];
            for (0..state.component_count) |component| {
                const index = first + component;
                const transferred = state.scratch_topsoil_pools[index] * fraction;
                state.scratch_topsoil_pools[index] -= transferred;
                state.scratch_pools[index] += transferred;
                state.scratch_transfer[index] = transferred;
            }
        } else {
            const deposited = -change;
            const suspended = state.sediment_megagrams[cell];
            if (deposited > suspended) return error.LocalDepositionExceedsSuspendedSediment;
            const fraction = if (deposited == 0) 0 else deposited / suspended;
            for (0..state.component_count) |component| {
                const index = first + component;
                const transferred = state.scratch_pools[index] * fraction;
                state.scratch_pools[index] -= transferred;
                state.scratch_topsoil_pools[index] += transferred;
                state.scratch_transfer[index] = -transferred;
            }
        }
        state.scratch_sediment_megagrams[cell] += change;
        state.scratch_topsoil_mass_megagrams[cell] -= change;
    }
    try validateNonnegativeFinite(state.scratch_sediment_megagrams);
    try validateNonnegativeFinite(state.scratch_topsoil_mass_megagrams);
    try validateNonnegativeFinite(state.scratch_pools);
    try validateNonnegativeFinite(state.scratch_topsoil_pools);
    try validateFinite(state.scratch_transfer);
    @memcpy(state.sediment_megagrams, state.scratch_sediment_megagrams);
    @memcpy(topsoil_mass_megagrams, state.scratch_topsoil_mass_megagrams);
    @memcpy(state.pools, state.scratch_pools);
    @memcpy(topsoil_pools, state.scratch_topsoil_pools);
    // Accepted diagnostics are the final part of the commit.  A failure above
    // therefore preserves both the previous scientific state and its previous
    // provenance sidecar.
    @memcpy(state.local_transfer_to_suspension, state.scratch_transfer);
    @memcpy(state.local_exchange_soil_layer_by_cell, topsoil_layer_by_cell);
    @memcpy(state.local_sediment_to_suspension_megagrams, net_detachment_megagrams);
}

/// Routes the existing suspended composition.  It never re-derives attached
/// composition from receiving or source topsoil, so retained sediment and
/// material detached in previous hours preserve provenance.  External face
/// losses are source-indexed in `exported` and `flux`.
pub fn route(
    state: *State,
    columns: usize,
    rows: usize,
    sediment: DirectionalSediment,
) !void {
    if (columns == 0 or rows == 0 or try std.math.mul(usize, columns, rows) != state.cell_count)
        return error.InvalidSuspendedConstituentDimensions;
    try state.validate();
    try validateDirectionalDimensions(state.cell_count, sediment);
    inline for (.{ sediment.east_megagrams, sediment.west_megagrams, sediment.south_megagrams, sediment.north_megagrams }) |values|
        try validateNonnegativeFinite(values);

    @memcpy(state.scratch_sediment_megagrams, state.sediment_megagrams);
    @memcpy(state.scratch_pools, state.pools);
    @memset(state.scratch_exported, 0);
    clearFlux(state.scratch_flux);

    for (0..state.cell_count) |cell| {
        const directional = [_]f64{
            sediment.east_megagrams[cell],
            sediment.west_megagrams[cell],
            sediment.south_megagrams[cell],
            sediment.north_megagrams[cell],
        };
        const outgoing = directional[0] + directional[1] + directional[2] + directional[3];
        const suspended = state.sediment_megagrams[cell];
        if (!std.math.isFinite(outgoing) or outgoing > suspended)
            return error.DirectionalSedimentExceedsSuspendedSediment;
        const first = cell * state.component_count;
        const output = [_][]f64{
            state.scratch_flux.east,
            state.scratch_flux.west,
            state.scratch_flux.south,
            state.scratch_flux.north,
        };
        for (directional, output) |sediment_flux, component_flux| {
            const fraction = if (sediment_flux == 0) 0 else sediment_flux / suspended;
            for (0..state.component_count) |component| {
                const index = first + component;
                component_flux[index] = state.pools[index] * fraction;
            }
        }
    }

    // All fallible validation is complete before any persistent mutation.
    for (0..rows) |row| for (0..columns) |column| {
        const source_cell = row * columns + column;
        const source_first = source_cell * state.component_count;
        const sediment_fluxes = [_]f64{
            sediment.east_megagrams[source_cell],
            sediment.west_megagrams[source_cell],
            sediment.south_megagrams[source_cell],
            sediment.north_megagrams[source_cell],
        };
        state.scratch_sediment_megagrams[source_cell] -= sediment_fluxes[0] + sediment_fluxes[1] + sediment_fluxes[2] + sediment_fluxes[3];
        if (column + 1 < columns) state.scratch_sediment_megagrams[source_cell + 1] += sediment_fluxes[0];
        if (column > 0) state.scratch_sediment_megagrams[source_cell - 1] += sediment_fluxes[1];
        if (row + 1 < rows) state.scratch_sediment_megagrams[source_cell + columns] += sediment_fluxes[2];
        if (row > 0) state.scratch_sediment_megagrams[source_cell - columns] += sediment_fluxes[3];

        const component_fluxes = [_][]const f64{
            state.scratch_flux.east,
            state.scratch_flux.west,
            state.scratch_flux.south,
            state.scratch_flux.north,
        };
        for (0..state.component_count) |component| {
            const source = source_first + component;
            const east = component_fluxes[0][source];
            const west = component_fluxes[1][source];
            const south = component_fluxes[2][source];
            const north = component_fluxes[3][source];
            state.scratch_pools[source] -= east + west + south + north;
            if (column + 1 < columns) state.scratch_pools[(source_cell + 1) * state.component_count + component] += east else state.scratch_exported[source] += east;
            if (column > 0) state.scratch_pools[(source_cell - 1) * state.component_count + component] += west else state.scratch_exported[source] += west;
            if (row + 1 < rows) state.scratch_pools[(source_cell + columns) * state.component_count + component] += south else state.scratch_exported[source] += south;
            if (row > 0) state.scratch_pools[(source_cell - columns) * state.component_count + component] += north else state.scratch_exported[source] += north;
        }
    };
    try validateNonnegativeFinite(state.scratch_sediment_megagrams);
    try validateNonnegativeFinite(state.scratch_pools);
    try validateNonnegativeFinite(state.scratch_exported);
    @memcpy(state.sediment_megagrams, state.scratch_sediment_megagrams);
    @memcpy(state.pools, state.scratch_pools);
    @memcpy(state.exported, state.scratch_exported);
    copyFlux(state.flux, state.scratch_flux);
}

/// Settles suspended sediment into a caller-packed receiving topsoil owner.
/// This must run immediately before the scalar pond-settling transaction,
/// using the same accepted settled mass, so attached and carrier mass share
/// one accounting time.
pub fn settle(
    state: *State,
    topsoil_mass_megagrams: []f64,
    topsoil_pools: []f64,
    settled_sediment_megagrams: []const f64,
) !void {
    if (topsoil_mass_megagrams.len != state.cell_count or
        topsoil_pools.len != state.pools.len or
        settled_sediment_megagrams.len != state.cell_count)
        return error.InvalidSuspendedConstituentDimensions;
    try validateNonnegativeFinite(topsoil_mass_megagrams);
    try stageAttachedSettlement(state, topsoil_pools, settled_sediment_megagrams);
    @memcpy(state.scratch_sediment_megagrams, state.sediment_megagrams);
    @memcpy(state.scratch_topsoil_mass_megagrams, topsoil_mass_megagrams);
    for (0..state.cell_count) |cell| {
        const settled = settled_sediment_megagrams[cell];
        state.scratch_sediment_megagrams[cell] -= settled;
        state.scratch_topsoil_mass_megagrams[cell] += settled;
    }
    try validateNonnegativeFinite(state.scratch_sediment_megagrams);
    try validateNonnegativeFinite(state.scratch_topsoil_mass_megagrams);
    @memcpy(state.sediment_megagrams, state.scratch_sediment_megagrams);
    @memcpy(topsoil_mass_megagrams, state.scratch_topsoil_mass_megagrams);
    commitStagedAttachedSettlement(state, topsoil_pools);
}

/// Preflights and stages attached-pool settlement without changing the
/// borrowed scalar sediment or receiving soil-mass carrier. This lets the
/// pond transaction commit those scalar owners exactly once after all other
/// particulate/chemistry owners have also passed preflight.
pub fn stageAttachedSettlement(
    state: *State,
    topsoil_pools: []const f64,
    settled_sediment_megagrams: []const f64,
) !void {
    if (topsoil_pools.len != state.pools.len or settled_sediment_megagrams.len != state.cell_count)
        return error.InvalidSuspendedConstituentDimensions;
    try state.validate();
    try validateNonnegativeFinite(topsoil_pools);
    try validateNonnegativeFinite(settled_sediment_megagrams);
    @memcpy(state.scratch_pools, state.pools);
    @memcpy(state.scratch_topsoil_pools, topsoil_pools);
    @memset(state.scratch_transfer, 0);
    for (0..state.cell_count) |cell| {
        const settled = settled_sediment_megagrams[cell];
        const scalar = state.sediment_megagrams[cell];
        if (settled > scalar) return error.SettlingExceedsSuspendedSediment;
        const fraction = if (settled == 0) 0 else settled / scalar;
        const first = cell * state.component_count;
        for (0..state.component_count) |component| {
            const index = first + component;
            const transferred = state.scratch_pools[index] * fraction;
            state.scratch_pools[index] -= transferred;
            state.scratch_topsoil_pools[index] += transferred;
            state.scratch_transfer[index] = transferred;
        }
    }
    try validateNonnegativeFinite(state.scratch_pools);
    try validateNonnegativeFinite(state.scratch_topsoil_pools);
    try validateNonnegativeFinite(state.scratch_transfer);
}

/// Infallible commit of a candidate produced by `stageAttachedSettlement`.
/// The caller owns the surrounding transaction and must commit only after all
/// of its other scientific owners have passed preflight.
pub fn commitStagedAttachedSettlement(state: *State, topsoil_pools: []f64) void {
    std.debug.assert(topsoil_pools.len == state.scratch_topsoil_pools.len);
    @memcpy(state.pools, state.scratch_pools);
    @memcpy(topsoil_pools, state.scratch_topsoil_pools);
    @memcpy(state.settled_transfer_to_topsoil, state.scratch_transfer);
}

fn allocFlux(allocator: std.mem.Allocator, count: usize) !DirectionalConstituentFlux {
    var result: DirectionalConstituentFlux = undefined;
    var allocated: usize = 0;
    errdefer {
        inline for (.{ "east", "west", "south", "north" }) |name| {
            if (allocated > 0) {
                allocated -= 1;
                allocator.free(@field(result, name));
            }
        }
    }
    inline for (.{ "east", "west", "south", "north" }) |name| {
        @field(result, name) = try allocator.alloc(f64, count);
        @memset(@field(result, name), 0);
        allocated += 1;
    }
    return result;
}

fn freeFlux(allocator: std.mem.Allocator, flux: DirectionalConstituentFlux) void {
    inline for (.{ flux.north, flux.south, flux.west, flux.east }) |values| allocator.free(values);
}

fn clearFlux(flux: DirectionalConstituentFlux) void {
    inline for (.{ flux.east, flux.west, flux.south, flux.north }) |values| @memset(values, 0);
}

fn copyFlux(destination: DirectionalConstituentFlux, source: DirectionalConstituentFlux) void {
    inline for (.{ "east", "west", "south", "north" }) |name| @memcpy(@field(destination, name), @field(source, name));
}

fn validateFluxDimensions(flux: DirectionalConstituentFlux, count: usize) !void {
    inline for (.{ flux.east, flux.west, flux.south, flux.north }) |values|
        if (values.len != count) return error.InvalidSuspendedConstituentDimensions;
}

fn validateDirectionalDimensions(cell_count: usize, sediment: DirectionalSediment) !void {
    inline for (.{ sediment.east_megagrams, sediment.west_megagrams, sediment.south_megagrams, sediment.north_megagrams }) |values|
        if (values.len != cell_count) return error.InvalidSuspendedConstituentDimensions;
}

fn validateFinite(values: []const f64) !void {
    for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteSuspendedConstituentState;
}

fn validateNonnegativeFinite(values: []const f64) !void {
    for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSuspendedConstituentState;
}

fn validatePositiveFinite(values: []const f64) !void {
    for (values) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidSuspendedConstituentCarrier;
}

const test_layout: Layout = .{
    .organic_cnp_count = 3,
    .nitrogen_fertilizer_count = 2,
    .dry_mineral_fertilizer_count = 2,
    .chemistry_live_and_pending_count = 2,
};

test "layout explicitly covers every required suspended owner family" {
    try test_layout.validate();
    try std.testing.expectEqual(@as(usize, 14), try test_layout.componentCount());
    try std.testing.expectEqual(Range{ .start = 0, .len = 3 }, try test_layout.range(.mineral_texture));
    try std.testing.expectEqual(Range{ .start = 3, .len = 2 }, try test_layout.range(.exchange_capacity));
    try std.testing.expectEqual(Range{ .start = 5, .len = 3 }, try test_layout.range(.organic_cnp));
    try std.testing.expectEqual(Range{ .start = 8, .len = 2 }, try test_layout.range(.nitrogen_fertilizer));
    try std.testing.expectEqual(Range{ .start = 10, .len = 2 }, try test_layout.range(.dry_mineral_fertilizer));
    try std.testing.expectEqual(Range{ .start = 12, .len = 2 }, try test_layout.range(.chemistry_live_and_pending));
}

test "family adapters preserve cell-major ownership and reject invalid candidates" {
    var packed_values = [_]f64{0} ** 28;
    const organic = [_]f64{ 1, 2, 3, 4, 5, 6 };
    try packFamily(test_layout, 2, .organic_cnp, &organic, &packed_values);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3 }, packed_values[5..8]);
    try std.testing.expectEqualSlices(f64, &.{ 4, 5, 6 }, packed_values[19..22]);
    var restored = [_]f64{0} ** 6;
    try unpackFamily(test_layout, 2, .organic_cnp, &packed_values, &restored);
    try std.testing.expectEqualSlices(f64, &organic, &restored);
    var invalid = organic;
    invalid[4] = -1;
    try std.testing.expectError(
        error.InvalidSuspendedConstituentState,
        packFamily(test_layout, 2, .organic_cnp, &invalid, &packed_values),
    );
}

test "local detachment and deposition conserve every family exactly" {
    var state = try State.init(std.testing.allocator, 1, test_layout);
    defer state.deinit();
    var topsoil: [14]f64 = undefined;
    for (&topsoil, 0..) |*value, index| value.* = @floatFromInt(index + 1);
    const initial = topsoil;
    var topsoil_mass = [_]f64{10};
    try exchangeLocal(&state, &topsoil_mass, &topsoil, &.{2}, &.{3});
    try std.testing.expectEqual(@as(f64, 2), state.sediment_megagrams[0]);
    try std.testing.expectEqual(@as(f64, 8), topsoil_mass[0]);
    try std.testing.expectEqual(@as(usize, 3), state.local_exchange_soil_layer_by_cell[0]);
    try std.testing.expectEqual(@as(f64, 2), state.local_sediment_to_suspension_megagrams[0]);
    for (0..14) |component| {
        try std.testing.expectApproxEqAbs(initial[component] * 0.8, topsoil[component], 1e-14);
        try std.testing.expectApproxEqAbs(initial[component] * 0.2, state.pools[component], 1e-14);
        try std.testing.expectApproxEqAbs(initial[component] * 0.2, state.local_transfer_to_suspension[component], 1e-14);
        try std.testing.expectApproxEqAbs(initial[component], topsoil[component] + state.pools[component], 1e-14);
    }
    try exchangeLocal(&state, &topsoil_mass, &topsoil, &.{-0.5}, &.{3});
    try std.testing.expectEqual(@as(f64, 1.5), state.sediment_megagrams[0]);
    try std.testing.expectEqual(@as(f64, 8.5), topsoil_mass[0]);
    for (0..14) |component|
        try std.testing.expectApproxEqAbs(initial[component], topsoil[component] + state.pools[component], 1e-14);
    try std.testing.expect(state.local_transfer_to_suspension[0] < 0);
    try std.testing.expectEqual(@as(usize, 3), state.local_exchange_soil_layer_by_cell[0]);
    try std.testing.expectEqual(@as(f64, -0.5), state.local_sediment_to_suspension_megagrams[0]);
}

test "routing preserves prior-hour suspended provenance and records boundary export" {
    var state = try State.init(std.testing.allocator, 2, test_layout);
    defer state.deinit();
    state.sediment_megagrams[0] = 4;
    state.pools[0] = 8; // deliberately unrelated to current topsoil
    state.pools[6] = 20;
    state.pools[13] = 12;
    try route(&state, 2, 1, .{
        .east_megagrams = &.{ 1, 0 },
        .west_megagrams = &.{ 1, 0 },
        .south_megagrams = &.{ 0, 0 },
        .north_megagrams = &.{ 0, 0 },
    });
    try std.testing.expectEqualSlices(f64, &.{ 2, 1 }, state.sediment_megagrams);
    try std.testing.expectApproxEqAbs(@as(f64, 4), state.pools[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2), state.pools[14], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 10), state.pools[6], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 3), state.pools[14 + 13], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2), state.exported[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 8), state.pools[0] + state.pools[14] + state.exported[0], 1e-14);
}

test "two-dimensional routing closes every component against source-indexed export" {
    var state = try State.init(std.testing.allocator, 4, test_layout);
    defer state.deinit();
    state.sediment_megagrams[0] = 10;
    state.sediment_megagrams[1] = 8;
    state.sediment_megagrams[2] = 6;
    state.sediment_megagrams[3] = 4;
    var initial = [_]f64{0} ** 14;
    for (0..4) |cell| for (0..14) |component| {
        const value = @as(f64, @floatFromInt((cell + 1) * (component + 1))) / 7;
        state.pools[cell * 14 + component] = value;
        initial[component] += value;
    };
    try route(&state, 2, 2, .{
        .east_megagrams = &.{ 1, 0.5, 0.75, 0.25 },
        .west_megagrams = &.{ 0.25, 0.5, 0.25, 0.5 },
        .south_megagrams = &.{ 0.5, 0.25, 0, 0 },
        .north_megagrams = &.{ 0.25, 0.25, 0.5, 0.25 },
    });
    for (0..14) |component| {
        var retained: f64 = 0;
        var exported: f64 = 0;
        for (0..4) |cell| {
            retained += state.pools[cell * 14 + component];
            exported += state.exported[cell * 14 + component];
        }
        const tolerance = 512 * std.math.floatEps(f64) * @max(1, initial[component]);
        try std.testing.expectApproxEqAbs(initial[component], retained + exported, tolerance);
    }
}

test "settling moves the suspended composition into topsoil without loss" {
    var state = try State.init(std.testing.allocator, 1, test_layout);
    defer state.deinit();
    state.sediment_megagrams[0] = 4;
    state.pools[0] = 8;
    state.pools[4] = 12;
    state.pools[5] = 16;
    state.pools[8] = 20;
    state.pools[10] = 24;
    state.pools[12] = 28;
    state.pools[13] = 32;
    var topsoil = [_]f64{0} ** 14;
    var topsoil_mass = [_]f64{10};
    try settle(&state, &topsoil_mass, &topsoil, &.{1});
    try std.testing.expectEqual(@as(f64, 3), state.sediment_megagrams[0]);
    try std.testing.expectEqual(@as(f64, 11), topsoil_mass[0]);
    inline for (.{ 0, 4, 5, 8, 10, 12, 13 }) |component| {
        try std.testing.expectApproxEqAbs(topsoil[component] * 3, state.pools[component], 1e-14);
        try std.testing.expectEqual(topsoil[component], state.settled_transfer_to_topsoil[component]);
    }
}

test "failed exchange route settle and restore leave persistent state unchanged" {
    var state = try State.init(std.testing.allocator, 1, test_layout);
    defer state.deinit();
    state.sediment_megagrams[0] = 1;
    state.pools[0] = 2;
    state.exported[0] = 3;
    state.flux.east[0] = 4;
    state.local_exchange_soil_layer_by_cell[0] = 6;
    state.local_sediment_to_suspension_megagrams[0] = 0.25;
    state.local_transfer_to_suspension[0] = 0.5;
    var topsoil = [_]f64{1} ** 14;
    var topsoil_mass = [_]f64{10};
    try std.testing.expectError(error.LocalDepositionExceedsSuspendedSediment, exchangeLocal(&state, &topsoil_mass, &topsoil, &.{-2}, &.{7}));
    try std.testing.expectEqual(@as(f64, 1), state.sediment_megagrams[0]);
    try std.testing.expectEqual(@as(f64, 2), state.pools[0]);
    try std.testing.expectEqual(@as(f64, 1), topsoil[0]);
    try std.testing.expectEqual(@as(usize, 6), state.local_exchange_soil_layer_by_cell[0]);
    try std.testing.expectEqual(@as(f64, 0.25), state.local_sediment_to_suspension_megagrams[0]);
    try std.testing.expectEqual(@as(f64, 0.5), state.local_transfer_to_suspension[0]);
    try std.testing.expectError(error.DirectionalSedimentExceedsSuspendedSediment, route(&state, 1, 1, .{
        .east_megagrams = &.{2},
        .west_megagrams = &.{0},
        .south_megagrams = &.{0},
        .north_megagrams = &.{0},
    }));
    try std.testing.expectEqual(@as(f64, 3), state.exported[0]);
    try std.testing.expectEqual(@as(f64, 4), state.flux.east[0]);
    try std.testing.expectError(error.SettlingExceedsSuspendedSediment, settle(&state, &topsoil_mass, &topsoil, &.{2}));
    try std.testing.expectEqual(@as(f64, 2), state.pools[0]);
    var invalid = [_]f64{0} ** 14;
    invalid[7] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidSuspendedConstituentState, state.restore(&.{0}, &invalid));
    try std.testing.expectEqual(@as(f64, 1), state.sediment_megagrams[0]);
    try std.testing.expectEqual(@as(f64, 2), state.pools[0]);
}

test "checkpoint restore round-trips persistent scalar and all attached pools" {
    var source = try State.init(std.testing.allocator, 2, test_layout);
    defer source.deinit();
    source.sediment_megagrams[0] = 1;
    source.sediment_megagrams[1] = 2;
    for (source.pools, 0..) |*value, index| value.* = @as(f64, @floatFromInt(index)) / 7;
    var restored = try State.init(std.testing.allocator, 2, test_layout);
    defer restored.deinit();
    try restored.restore(source.sediment_megagrams, source.pools);
    try std.testing.expectEqualSlices(f64, source.sediment_megagrams, restored.sediment_megagrams);
    try std.testing.expectEqualSlices(f64, source.pools, restored.pools);
    const zero = [_]f64{0} ** 28;
    try std.testing.expectEqualSlices(f64, &zero, restored.exported);
}

test "borrowed scalar storage remains authoritative and is not freed by state" {
    const scalar = try std.testing.allocator.alloc(f64, 1);
    defer std.testing.allocator.free(scalar);
    scalar[0] = 0;
    var state = try State.initBorrowingSediment(std.testing.allocator, scalar, test_layout);
    var topsoil = [_]f64{1} ** 14;
    var topsoil_mass = [_]f64{10};
    try exchangeLocal(&state, &topsoil_mass, &topsoil, &.{1}, &.{0});
    try std.testing.expectEqual(@as(f64, 1), scalar[0]);
    state.deinit();
    try std.testing.expectEqual(@as(f64, 1), scalar[0]);
}

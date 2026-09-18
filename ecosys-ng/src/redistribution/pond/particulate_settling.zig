const std = @import("std");

/// Unit carried by one extensive particulate inventory.
///
/// REDIST settles pools with different units using the same dimensionless
/// fraction. Values are never summed across unlike units.
pub const ExtensiveUnit = enum {
    megagrams,
    moles,
    grams_carbon,
    grams_nitrogen,
    grams_phosphorus,
};

pub const DiagnosticRole = enum {
    particulate_inventory,
    mineral_sediment_mass,
};

/// One runtime-layer extensive inventory. The caller supplies pools in the
/// legacy REDIST calculation order when intermediate diagnostics depend on it.
pub const Pool = struct {
    name: []const u8,
    unit: ExtensiveUnit,
    diagnostic_role: DiagnosticRole = .particulate_inventory,
    amount_by_layer: []f64,
};

pub const Geometry = struct {
    /// Bulk density by runtime layer (Mg m-3); zero denotes pond water.
    bulk_density_megagrams_per_m3: []const f64,
    /// Current layer thickness by runtime layer (m).
    layer_thickness_m: []const f64,
    /// Fortran NL, converted to a zero-based inclusive layer index.
    last_layer: usize,
    /// Fortran NU, converted to a zero-based soil-surface layer index.
    surface_soil_layer: usize,
    /// Fortran DLYRM: minimum thickness for a receiving layer (m).
    minimum_receiver_thickness_m: f64,
};

pub const Options = struct {
    /// Fortran XNFH: current science-step duration (h).
    timestep_h: f64,
    /// Active compatibility formulation from redist.f line 352 (h-1).
    settling_rate_per_h: f64 = 0.001,
};

pub const Result = struct {
    /// Mineral sediment newly delivered into positive-density layers (Mg).
    deposited_mineral_sediment_megagrams: f64,
    /// Deepest positive-density receiver that accepted sediment, if any.
    deepest_deposition_layer: ?usize,
};

/// Geometry needed to evaluate the REDIST line 344--348 donor guard for the
/// separated surface owner. Soil arrays use cell-major local-layer indexing.
/// The separate donor precedes `surface_soil_layer_by_cell[cell]` in the
/// legacy traversal.
pub const SeparatedSurfaceGeometry = struct {
    cell_count: usize,
    soil_layer_capacity: usize,
    donor_bulk_density_megagrams_per_m3: []const f64,
    donor_layer_thickness_m: []const f64,
    surface_soil_layer_by_cell: []const usize,
    active_soil_layer_count_by_cell: []const usize,
    soil_bulk_density_megagrams_per_m3: []const f64,
    soil_layer_thickness_m: []const f64,
    minimum_receiver_thickness_m: f64,
};

/// A validated view keeps domain preflight separate from per-cell selection,
/// so callers can preserve atomic mutation without repeating an O(domain)
/// validation for every cell.
pub const SeparatedSurfaceEligibility = struct {
    geometry: SeparatedSurfaceGeometry,

    pub fn init(geometry: SeparatedSurfaceGeometry) !SeparatedSurfaceEligibility {
        try validateSeparatedSurfaceGeometry(geometry);
        return .{ .geometry = geometry };
    }

    /// Returns REDIST's first deeper thickness-valid receiver, or null when the
    /// separated L=0 donor fails the density/thickness predicate. Receiver
    /// density is deliberately irrelevant: `redist.f:347--350` tests only
    /// `DLYR>DLYRM`. Moving L=0 material into the first represented pond-water
    /// layer after that layer's descending turn preserves its one-hour water-
    /// column residence instead of jumping directly to the mineral bed.
    pub fn receiver(self: SeparatedSurfaceEligibility, cell: usize) !?usize {
        if (cell >= self.geometry.cell_count)
            return error.PondSettlingCellOutOfBounds;
        const geometry = self.geometry;
        const soil_base = cell * geometry.soil_layer_capacity;
        const surface_soil_layer = geometry.surface_soil_layer_by_cell[cell];
        const active_soil_layer_end = surface_soil_layer +
            geometry.active_soil_layer_count_by_cell[cell];
        const surface_over_pond =
            geometry.soil_bulk_density_megagrams_per_m3[soil_base + surface_soil_layer] <= 0;
        const donor_is_water =
            geometry.donor_bulk_density_megagrams_per_m3[cell] <= 0;
        if (!(donor_is_water or surface_over_pond) or
            geometry.donor_layer_thickness_m[cell] <= 0)
            return null;

        var receiver_layer = surface_soil_layer;
        while (receiver_layer < active_soil_layer_end) : (receiver_layer += 1) {
            if (geometry.soil_layer_thickness_m[soil_base + receiver_layer] >
                geometry.minimum_receiver_thickness_m)
                return receiver_layer;
        }
        return error.MissingPondSettlingReceiver;
    }

    /// REDIST `L>0` donor/receiver selection (`redist.f:343--350`). The caller
    /// traverses donors deepest-first; this method deliberately considers only
    /// the source's current geometry and returns the first deeper layer whose
    /// thickness exceeds DLYRM. Receiver bulk density is not a gate.
    pub fn soilReceiver(self: SeparatedSurfaceEligibility, cell: usize, source_layer: usize) !?usize {
        if (cell >= self.geometry.cell_count)
            return error.PondSettlingCellOutOfBounds;
        const geometry = self.geometry;
        const base = cell * geometry.soil_layer_capacity;
        const first = geometry.surface_soil_layer_by_cell[cell];
        const end = first + geometry.active_soil_layer_count_by_cell[cell];
        if (source_layer < first or source_layer >= end)
            return error.PondSettlingLayerOutOfBounds;
        if (source_layer + 1 >= end or
            geometry.soil_bulk_density_megagrams_per_m3[base + source_layer] > 0 or
            geometry.soil_layer_thickness_m[base + source_layer] <= 0)
            return null;
        var receiver_layer = source_layer + 1;
        while (receiver_layer < end) : (receiver_layer += 1) {
            if (geometry.soil_layer_thickness_m[base + receiver_layer] >
                geometry.minimum_receiver_thickness_m)
                return receiver_layer;
        }
        return error.MissingPondSettlingReceiver;
    }
};

/// Returns the first represented mineral layer in a column. Open-water
/// layers remain part of settling topology, but they are not valid dry-soil
/// carriers for erosion or per-mineral-mass source properties.
pub const MineralColumnGeometry = struct {
    cell_count: usize,
    soil_layer_capacity: usize,
    surface_soil_layer_by_cell: []const usize,
    active_soil_layer_count_by_cell: []const usize,
    soil_bulk_density_megagrams_per_m3: []const f64,
    matrix_bulk_volume_m3: []const f64,
};

pub fn firstMineralLayer(
    geometry: MineralColumnGeometry,
    cell: usize,
) !usize {
    if (geometry.cell_count == 0 or geometry.soil_layer_capacity == 0 or
        geometry.surface_soil_layer_by_cell.len != geometry.cell_count or
        geometry.active_soil_layer_count_by_cell.len != geometry.cell_count)
        return error.PondSettlingGeometryDimensionMismatch;
    const slot_count = try std.math.mul(usize, geometry.cell_count, geometry.soil_layer_capacity);
    if (geometry.soil_bulk_density_megagrams_per_m3.len != slot_count or
        geometry.matrix_bulk_volume_m3.len != slot_count)
        return error.PondSettlingGeometryDimensionMismatch;
    if (cell >= geometry.cell_count) return error.PondSettlingCellOutOfBounds;
    const base = cell * geometry.soil_layer_capacity;
    const first = geometry.surface_soil_layer_by_cell[cell];
    const active = geometry.active_soil_layer_count_by_cell[cell];
    if (active == 0 or first >= geometry.soil_layer_capacity or
        active > geometry.soil_layer_capacity - first)
        return error.PondSettlingGeometryDimensionMismatch;
    const end = first + active;
    for (first..end) |local| {
        const density = geometry.soil_bulk_density_megagrams_per_m3[base + local];
        const volume = geometry.matrix_bulk_volume_m3[base + local];
        if (!std.math.isFinite(density) or density < 0 or
            !std.math.isFinite(volume) or volume <= 0)
            return error.InvalidPondSettlingGeometry;
        if (density > 0) return local;
    }
    return error.MissingPondMineralLayer;
}

/// Returns the REDIST compatibility settling fraction after applying the same
/// finite-value and physical-domain checks used by `settle`.
pub fn settlingFraction(options: Options) !f64 {
    if (!std.math.isFinite(options.timestep_h) or options.timestep_h < 0 or
        !std.math.isFinite(options.settling_rate_per_h) or
        options.settling_rate_per_h < 0)
        return error.InvalidPondSettlingControl;
    const fraction = options.settling_rate_per_h * options.timestep_h;
    if (!std.math.isFinite(fraction) or fraction > 1)
        return error.InvalidPondSettlingFraction;
    return fraction;
}

/// Settles pond particulates in the exact source traversal order.
///
/// Traceability: REDIST (`redist.f`) lines 333-614. Donors are visited from
/// `NL-1` through layer zero. The first deeper layer thicker than DLYRM is the
/// receiver. Descending traversal is scientifically significant: material
/// received by a deeper layer is not settled again during the same call.
pub fn settle(
    geometry: Geometry,
    pools: []const Pool,
    options: Options,
) !Result {
    try validate(geometry, pools, options);
    const settling_fraction = try settlingFraction(options);

    var result: Result = .{
        .deposited_mineral_sediment_megagrams = 0,
        .deepest_deposition_layer = null,
    };
    if (geometry.last_layer == 0 or settling_fraction == 0) return result;

    var donor = geometry.last_layer;
    while (donor > 0) {
        donor -= 1;
        if (!isPondDonor(geometry, donor)) continue;
        const receiver = firstReceiver(geometry, donor) orelse
            return error.MissingPondSettlingReceiver;

        for (pools) |pool| {
            const transfer = settling_fraction * pool.amount_by_layer[donor];
            pool.amount_by_layer[donor] -= transfer;
            pool.amount_by_layer[receiver] += transfer;
            if (pool.diagnostic_role == .mineral_sediment_mass and
                geometry.bulk_density_megagrams_per_m3[receiver] > 0)
            {
                result.deposited_mineral_sediment_megagrams += transfer;
                result.deepest_deposition_layer = receiver;
            }
        }
    }
    return result;
}

fn isPondDonor(geometry: Geometry, layer: usize) bool {
    const water_layer = geometry.bulk_density_megagrams_per_m3[layer] <= 0;
    const surface_over_pond =
        layer == 0 and
        geometry.bulk_density_megagrams_per_m3[geometry.surface_soil_layer] <= 0;
    return (water_layer or surface_over_pond) and
        geometry.layer_thickness_m[layer] > 0;
}

fn firstReceiver(geometry: Geometry, donor: usize) ?usize {
    var receiver = donor + 1;
    while (receiver <= geometry.last_layer) : (receiver += 1) {
        if (geometry.layer_thickness_m[receiver] >
            geometry.minimum_receiver_thickness_m) return receiver;
    }
    return null;
}

fn validateSeparatedSurfaceGeometry(geometry: SeparatedSurfaceGeometry) !void {
    if (geometry.cell_count == 0 or geometry.soil_layer_capacity == 0 or
        geometry.donor_bulk_density_megagrams_per_m3.len != geometry.cell_count or
        geometry.donor_layer_thickness_m.len != geometry.cell_count or
        geometry.surface_soil_layer_by_cell.len != geometry.cell_count or
        geometry.active_soil_layer_count_by_cell.len != geometry.cell_count)
        return error.PondSettlingGeometryDimensionMismatch;
    const soil_slot_count = std.math.mul(
        usize,
        geometry.cell_count,
        geometry.soil_layer_capacity,
    ) catch return error.PondSettlingGeometryDimensionMismatch;
    if (geometry.soil_bulk_density_megagrams_per_m3.len != soil_slot_count or
        geometry.soil_layer_thickness_m.len != soil_slot_count)
        return error.PondSettlingGeometryDimensionMismatch;
    if (!std.math.isFinite(geometry.minimum_receiver_thickness_m) or
        geometry.minimum_receiver_thickness_m < 0)
        return error.InvalidPondSettlingControl;

    for (0..geometry.cell_count) |cell| {
        const active_count = geometry.active_soil_layer_count_by_cell[cell];
        const surface_soil_layer = geometry.surface_soil_layer_by_cell[cell];
        if (active_count == 0 or surface_soil_layer >= geometry.soil_layer_capacity or
            active_count > geometry.soil_layer_capacity - surface_soil_layer)
            return error.PondSettlingGeometryDimensionMismatch;
        inline for (.{
            geometry.donor_bulk_density_megagrams_per_m3[cell],
            geometry.donor_layer_thickness_m[cell],
        }) |value| if (!std.math.isFinite(value) or value < 0)
            return error.InvalidPondSettlingGeometry;
    }
    for (geometry.soil_bulk_density_megagrams_per_m3, geometry.soil_layer_thickness_m) |
        density,
        thickness,
    | if (!std.math.isFinite(density) or density < 0 or
        !std.math.isFinite(thickness) or thickness < 0)
        return error.InvalidPondSettlingGeometry;
}

fn validate(geometry: Geometry, pools: []const Pool, options: Options) !void {
    const layer_count = geometry.bulk_density_megagrams_per_m3.len;
    if (layer_count == 0 or geometry.layer_thickness_m.len != layer_count or
        geometry.last_layer >= layer_count or
        geometry.surface_soil_layer >= layer_count)
        return error.PondSettlingGeometryDimensionMismatch;
    if (!std.math.isFinite(geometry.minimum_receiver_thickness_m) or
        geometry.minimum_receiver_thickness_m < 0)
        return error.InvalidPondSettlingControl;
    _ = try settlingFraction(options);

    for (geometry.bulk_density_megagrams_per_m3, geometry.layer_thickness_m) |
        density,
        thickness,
    | {
        if (!std.math.isFinite(density) or density < 0 or
            !std.math.isFinite(thickness) or thickness < 0)
            return error.InvalidPondSettlingGeometry;
    }
    if (geometry.last_layer > 0) {
        var donor = geometry.last_layer;
        while (donor > 0) {
            donor -= 1;
            if (isPondDonor(geometry, donor) and
                firstReceiver(geometry, donor) == null)
                return error.MissingPondSettlingReceiver;
        }
    }
    for (pools) |pool| {
        if (pool.name.len == 0 or pool.amount_by_layer.len != layer_count)
            return error.PondSettlingPoolDimensionMismatch;
        var total: f64 = 0;
        for (pool.amount_by_layer) |amount| {
            if (!std.math.isFinite(amount) or amount < 0)
                return error.InvalidPondParticulateInventory;
            total += amount;
            if (!std.math.isFinite(total))
                return error.PondParticulateInventoryOverflow;
        }
    }
}

test "REDIST descending order prevents same-step settling cascade" {
    var sediment = [_]f64{ 100, 50, 0 };
    var carbon = [_]f64{ 20, 10, 0 };
    const pools = [_]Pool{
        .{
            .name = "sand",
            .unit = .megagrams,
            .diagnostic_role = .mineral_sediment_mass,
            .amount_by_layer = &sediment,
        },
        .{
            .name = "microbial carbon",
            .unit = .grams_carbon,
            .amount_by_layer = &carbon,
        },
    };

    const result = try settle(.{
        .bulk_density_megagrams_per_m3 = &.{ 0, 0, 1.2 },
        .layer_thickness_m = &.{ 0.1, 0.1, 0.2 },
        .last_layer = 2,
        .surface_soil_layer = 2,
        .minimum_receiver_thickness_m = 1e-6,
    }, &pools, .{ .timestep_h = 1 });

    // Layer 1 settles first. Layer 0 then settles into layer 1, after its turn.
    try std.testing.expectApproxEqAbs(@as(f64, 99.9), sediment[0], 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 50.05), sediment[1], 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), sediment[2], 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), result.deposited_mineral_sediment_megagrams, 1e-13);
    try std.testing.expectEqual(@as(?usize, 2), result.deepest_deposition_layer);
}

test "mixed-unit particulate pools conserve each extensive inventory" {
    var mineral = [_]f64{ 2, 0 };
    var phosphorus = [_]f64{ 31, 0 };
    var exchange_sites = [_]f64{ 4, 0 };
    const pools = [_]Pool{
        .{ .name = "clay", .unit = .megagrams, .diagnostic_role = .mineral_sediment_mass, .amount_by_layer = &mineral },
        .{ .name = "organic phosphorus", .unit = .grams_phosphorus, .amount_by_layer = &phosphorus },
        .{ .name = "cation exchange capacity", .unit = .moles, .amount_by_layer = &exchange_sites },
    };

    _ = try settle(.{
        .bulk_density_megagrams_per_m3 = &.{ 0, 1.1 },
        .layer_thickness_m = &.{ 0.2, 0.2 },
        .last_layer = 1,
        .surface_soil_layer = 1,
        .minimum_receiver_thickness_m = 0,
    }, &pools, .{ .timestep_h = 2 });

    try std.testing.expectApproxEqAbs(@as(f64, 2), mineral[0] + mineral[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 31), phosphorus[0] + phosphorus[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 4), exchange_sites[0] + exchange_sites[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.004), mineral[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.062), phosphorus[1], 1e-14);
}

test "zero-thickness layers are skipped when selecting receiver" {
    var nitrogen = [_]f64{ 10, 0, 0 };
    const pools = [_]Pool{
        .{ .name = "microbial nitrogen", .unit = .grams_nitrogen, .amount_by_layer = &nitrogen },
    };
    _ = try settle(.{
        .bulk_density_megagrams_per_m3 = &.{ 0, 0, 1 },
        .layer_thickness_m = &.{ 0.1, 1e-7, 0.2 },
        .last_layer = 2,
        .surface_soil_layer = 2,
        .minimum_receiver_thickness_m = 1e-6,
    }, &pools, .{ .timestep_h = 1 });
    try std.testing.expectEqual(@as(f64, 0), nitrogen[1]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), nitrogen[2], 1e-15);
}

test "separated surface eligibility uses density and thickness rather than water retention" {
    const eligibility = try SeparatedSurfaceEligibility.init(.{
        .cell_count = 3,
        .soil_layer_capacity = 2,
        .donor_bulk_density_megagrams_per_m3 = &.{ 0, 1.2, 1.2 },
        .donor_layer_thickness_m = &.{ 0.1, 0.1, 0.1 },
        .surface_soil_layer_by_cell = &.{ 0, 0, 0 },
        .active_soil_layer_count_by_cell = &.{ 2, 2, 2 },
        .soil_bulk_density_megagrams_per_m3 = &.{ 1.2, 1.3, 1.2, 1.3, 0, 1.3 },
        .soil_layer_thickness_m = &.{ 0, 0.2, 0.2, 0.2, 0.2, 0.2 },
        .minimum_receiver_thickness_m = 1e-6,
    });

    // Water donor: skip the zero-thickness first soil slot.
    try std.testing.expectEqual(@as(?usize, 1), try eligibility.receiver(0));
    // Positive-density donor over positive-density soil: ineligible.
    try std.testing.expectEqual(@as(?usize, null), try eligibility.receiver(1));
    // REDIST's L == 0 surface-over-pond special case remains eligible. Its
    // first thickness-valid receiver is the represented water layer itself;
    // density is not part of redist.f:347--350's receiver predicate.
    try std.testing.expectEqual(@as(?usize, 0), try eligibility.receiver(2));
}

test "invalid late separated geometry is rejected during atomic preflight" {
    try std.testing.expectError(
        error.InvalidPondSettlingGeometry,
        SeparatedSurfaceEligibility.init(.{
            .cell_count = 2,
            .soil_layer_capacity = 1,
            .donor_bulk_density_megagrams_per_m3 = &.{ 0, 0 },
            .donor_layer_thickness_m = &.{ 0.1, 0.1 },
            .surface_soil_layer_by_cell = &.{ 0, 0 },
            .active_soil_layer_count_by_cell = &.{ 1, 1 },
            .soil_bulk_density_megagrams_per_m3 = &.{ 1.2, 1.2 },
            .soil_layer_thickness_m = &.{ 0.2, std.math.nan(f64) },
            .minimum_receiver_thickness_m = 0,
        }),
    );
}

test "separated receiver range starts at a nonzero runtime surface layer" {
    const eligibility = try SeparatedSurfaceEligibility.init(.{
        .cell_count = 1,
        .soil_layer_capacity = 4,
        .donor_bulk_density_megagrams_per_m3 = &.{0},
        .donor_layer_thickness_m = &.{0.1},
        .surface_soil_layer_by_cell = &.{2},
        .active_soil_layer_count_by_cell = &.{2},
        .soil_bulk_density_megagrams_per_m3 = &.{ 0, 0, 1.2, 1.3 },
        .soil_layer_thickness_m = &.{ 0, 0, 0, 0.2 },
        .minimum_receiver_thickness_m = 1e-6,
    });

    try std.testing.expectEqual(@as(?usize, 3), try eligibility.receiver(0));
}

test "open-water topology retains zero-density layers before the mineral carrier" {
    const geometry: MineralColumnGeometry = .{
        .cell_count = 1,
        .soil_layer_capacity = 4,
        .surface_soil_layer_by_cell = &.{0},
        .active_soil_layer_count_by_cell = &.{4},
        .soil_bulk_density_megagrams_per_m3 = &.{ 0, 0, 1.2, 1.3 },
        .matrix_bulk_volume_m3 = &.{ 2, 2, 3, 4 },
    };
    try std.testing.expectEqual(@as(usize, 2), try firstMineralLayer(geometry, 0));
}

test "invalid late pool leaves all pools unchanged" {
    var valid = [_]f64{ 8, 0 };
    var invalid = [_]f64{ 2, -1 };
    const before = valid;
    const pools = [_]Pool{
        .{ .name = "valid", .unit = .moles, .amount_by_layer = &valid },
        .{ .name = "invalid", .unit = .moles, .amount_by_layer = &invalid },
    };
    try std.testing.expectError(error.InvalidPondParticulateInventory, settle(.{
        .bulk_density_megagrams_per_m3 = &.{ 0, 1 },
        .layer_thickness_m = &.{ 0.1, 0.1 },
        .last_layer = 1,
        .surface_soil_layer = 1,
        .minimum_receiver_thickness_m = 0,
    }, &pools, .{ .timestep_h = 1 }));
    try std.testing.expectEqualSlices(f64, &before, &valid);
}

test "missing receiver is rejected before any pool mutation" {
    var inventory = [_]f64{ 5, 0 };
    const before = inventory;
    const pools = [_]Pool{
        .{ .name = "particulate", .unit = .moles, .amount_by_layer = &inventory },
    };
    try std.testing.expectError(error.MissingPondSettlingReceiver, settle(.{
        .bulk_density_megagrams_per_m3 = &.{ 0, 0 },
        .layer_thickness_m = &.{ 0.1, 0 },
        .last_layer = 1,
        .surface_soil_layer = 1,
        .minimum_receiver_thickness_m = 0,
    }, &pools, .{ .timestep_h = 1 }));
    try std.testing.expectEqualSlices(f64, &before, &inventory);
}

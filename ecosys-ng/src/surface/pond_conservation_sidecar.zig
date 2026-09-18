const std = @import("std");

/// Exact extensive transfer published by an accepted pond/sediment producer.
/// Nitrogen and phosphorus have both native-mole and organic-gram lanes: the
/// former are converted by the layer reducer with the runscript molar masses,
/// while organic pools are already stored in grams.  Keeping the native mole
/// lanes prevents producer-side unit guesses and makes stoichiometry explicit.
pub const Transfer = struct {
    water_m3: f64 = 0,
    heat_megajoules: f64 = 0,
    carbon_g: f64 = 0,
    carbon_mol: f64 = 0,
    oxygen_g: f64 = 0,
    hydrogen_g: f64 = 0,
    nitrogen_g: f64 = 0,
    phosphorus_g: f64 = 0,
    nitrogen_mol: f64 = 0,
    phosphorus_mol: f64 = 0,
    aluminum_mol: f64 = 0,
    iron_mol: f64 = 0,
    calcium_mol: f64 = 0,
    magnesium_mol: f64 = 0,
    sodium_mol: f64 = 0,
    potassium_mol: f64 = 0,
    sulfur_mol: f64 = 0,
    chloride_mol: f64 = 0,
    silicon_mol: f64 = 0,
    sand_megagrams: f64 = 0,
    silt_megagrams: f64 = 0,
    clay_megagrams: f64 = 0,
    cation_exchange_capacity_mol: f64 = 0,
    anion_exchange_capacity_mol: f64 = 0,

    pub fn validate(self: Transfer) !void {
        inline for (std.meta.fields(Transfer)) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidPondAcceptedTransfer;
        }
    }

    pub fn add(self: Transfer, other: Transfer) !Transfer {
        try self.validate();
        try other.validate();
        var result: Transfer = .{};
        inline for (std.meta.fields(Transfer)) |field| {
            @field(result, field.name) = @field(self, field.name) + @field(other, field.name);
            if (!std.math.isFinite(@field(result, field.name)))
                return error.PondAcceptedTransferOverflow;
        }
        return result;
    }
};

/// Borrowed producer outputs. `active=false` means no accepted cross-domain
/// transfer and the transfer must be exactly zero. Destination indices are
/// runtime-logical soil-layer coordinates, not flattened storage indices.
pub const CellSidecar = struct {
    active: []bool,
    destination_soil_layer: []usize,
    transfer: []Transfer,

    pub fn validateDimensions(self: CellSidecar, cell_count: usize) !void {
        if (self.active.len != cell_count or
            self.destination_soil_layer.len != cell_count or
            self.transfer.len != cell_count)
            return error.PondAcceptedTransferDimensionMismatch;
    }

    pub fn clear(self: CellSidecar) void {
        @memset(self.active, false);
        @memset(self.destination_soil_layer, 0);
        @memset(self.transfer, .{});
    }
};

/// Source-indexed accepted soil-layer transfer. Arrays are flattened
/// cell-major at `cell * layer_capacity + source_logical_layer`; the paired
/// destination remains a runtime-logical layer index in the same cell.
pub const SoilLayerSidecar = struct {
    active_by_source: []bool,
    destination_soil_layer_by_source: []usize,
    transfer_by_source: []Transfer,

    pub fn validateDimensions(self: SoilLayerSidecar, layer_count: usize) !void {
        if (self.active_by_source.len != layer_count or
            self.destination_soil_layer_by_source.len != layer_count or
            self.transfer_by_source.len != layer_count)
            return error.PondAcceptedTransferDimensionMismatch;
    }

    pub fn clear(self: SoilLayerSidecar) void {
        @memset(self.active_by_source, false);
        @memset(self.destination_soil_layer_by_source, 0);
        @memset(self.transfer_by_source, .{});
    }
};

test "accepted transfer addition rejects invalid and preserves every lane" {
    const result = try (Transfer{
        .water_m3 = 1,
        .carbon_g = 2,
        .nitrogen_mol = 3,
        .sand_megagrams = 4,
    }).add(.{
        .heat_megajoules = 5,
        .nitrogen_g = 6,
        .calcium_mol = 7,
        .cation_exchange_capacity_mol = 8,
    });
    try std.testing.expectEqual(@as(f64, 1), result.water_m3);
    try std.testing.expectEqual(@as(f64, 5), result.heat_megajoules);
    try std.testing.expectEqual(@as(f64, 2), result.carbon_g);
    try std.testing.expectEqual(@as(f64, 6), result.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 3), result.nitrogen_mol);
    try std.testing.expectEqual(@as(f64, 7), result.calcium_mol);
    try std.testing.expectEqual(@as(f64, 4), result.sand_megagrams);
    try std.testing.expectEqual(@as(f64, 8), result.cation_exchange_capacity_mol);
    try std.testing.expectError(
        error.InvalidPondAcceptedTransfer,
        (Transfer{ .water_m3 = -1 }).add(.{}),
    );
}

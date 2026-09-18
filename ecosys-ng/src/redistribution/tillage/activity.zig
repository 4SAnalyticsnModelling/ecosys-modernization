const std = @import("std");
const inventory = @import("../../validation/landscape_mass_inventory_support.zig");

pub const Tolerance = struct {
    absolute: inventory.Storage = .{},
    relative: f64,
    representation_ulps: u16 = 64,

    fn validate(self: Tolerance) !void {
        try self.absolute.validate();
        inline for (std.meta.fields(inventory.Storage)) |field|
            if (@field(self.absolute, field.name) < 0)
                return error.InvalidTillageActivityTolerance;
        if (!std.math.isFinite(self.relative) or self.relative < 0 or self.representation_ulps == 0)
            return error.InvalidTillageActivityTolerance;
    }
};

/// One exact ordered gross transfer. Material follows the record's named
/// donor and recipient. Negative reference enthalpy reverses only heat; the
/// stored heat coordinate is always a magnitude.
pub const Record = struct {
    active: bool = false,
    heat_reversed: bool = false,
    transfer: inventory.Storage = .{},
};

/// Attempt-atomic producer output. Soil records are indexed
/// `[cell][donor][recipient]`; diagonal records are always empty. Surface
/// records are indexed `[cell][recipient]` and name surface as the donor.
pub const Sidecar = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    layer_capacity: usize,
    tolerance: Tolerance,
    accepted_soil: []Record,
    staged_soil: []Record,
    accepted_surface: []Record,
    staged_surface: []Record,
    staged_cell: []bool,
    attempt_active: bool = false,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, layer_capacity: usize, tolerance: Tolerance) !Sidecar {
        if (cell_count == 0 or layer_capacity == 0) return error.InvalidTillageActivityDimensions;
        try tolerance.validate();
        const cell_layers = try std.math.mul(usize, cell_count, layer_capacity);
        const soil_count = try std.math.mul(usize, cell_layers, layer_capacity);
        const accepted_soil = try allocator.alloc(Record, soil_count);
        errdefer allocator.free(accepted_soil);
        const staged_soil = try allocator.alloc(Record, soil_count);
        errdefer allocator.free(staged_soil);
        const accepted_surface = try allocator.alloc(Record, cell_layers);
        errdefer allocator.free(accepted_surface);
        const staged_surface = try allocator.alloc(Record, cell_layers);
        errdefer allocator.free(staged_surface);
        const staged_cell = try allocator.alloc(bool, cell_count);
        @memset(accepted_soil, .{});
        @memset(staged_soil, .{});
        @memset(accepted_surface, .{});
        @memset(staged_surface, .{});
        @memset(staged_cell, false);
        return .{ .allocator = allocator, .cell_count = cell_count, .layer_capacity = layer_capacity, .tolerance = tolerance, .accepted_soil = accepted_soil, .staged_soil = staged_soil, .accepted_surface = accepted_surface, .staged_surface = staged_surface, .staged_cell = staged_cell };
    }

    pub fn deinit(self: *Sidecar) void {
        self.allocator.free(self.staged_cell);
        self.allocator.free(self.staged_surface);
        self.allocator.free(self.accepted_surface);
        self.allocator.free(self.staged_soil);
        self.allocator.free(self.accepted_soil);
        self.* = undefined;
    }

    pub fn beginAttempt(self: *Sidecar) !void {
        if (self.attempt_active) return error.TillageActivityAttemptAlreadyActive;
        @memset(self.staged_soil, .{});
        @memset(self.staged_surface, .{});
        @memset(self.staged_cell, false);
        self.attempt_active = true;
    }

    pub fn abortAttempt(self: *Sidecar) void {
        if (!self.attempt_active) return;
        @memset(self.staged_soil, .{});
        @memset(self.staged_surface, .{});
        @memset(self.staged_cell, false);
        self.attempt_active = false;
    }

    pub fn commitAttempt(self: *Sidecar) !void {
        if (!self.attempt_active) return error.TillageActivityAttemptNotActive;
        @memcpy(self.accepted_soil, self.staged_soil);
        @memcpy(self.accepted_surface, self.staged_surface);
        self.attempt_active = false;
    }

    fn soilIndex(self: Sidecar, cell: usize, donor: usize, recipient: usize) usize {
        return (cell * self.layer_capacity + donor) * self.layer_capacity + recipient;
    }

    pub fn validateLayout(self: *const Sidecar, cell_count: usize, layer_capacity: usize) !void {
        if (self.cell_count != cell_count or self.layer_capacity != layer_capacity)
            return error.TillageActivityDimensionMismatch;
    }

    pub fn soilRecord(self: *const Sidecar, cell: usize, donor: usize, recipient: usize) !Record {
        if (cell >= self.cell_count or donor >= self.layer_capacity or recipient >= self.layer_capacity)
            return error.TillageActivityLayerOutOfBounds;
        return self.accepted_soil[self.soilIndex(cell, donor, recipient)];
    }

    pub fn surfaceRecord(self: *const Sidecar, cell: usize, recipient: usize) !Record {
        if (cell >= self.cell_count or recipient >= self.layer_capacity)
            return error.TillageActivityLayerOutOfBounds;
        return self.accepted_surface[cell * self.layer_capacity + recipient];
    }

    /// Derives gross transfers from the exact REDIST matrix:
    /// `m * ti(donor) * fi(recipient) * before(donor)`. The self term is
    /// excluded because it never crosses a control-volume boundary. Surface
    /// incorporation uses the producer's already-extensive accepted amount
    /// and the same `fi` recipient weights.
    pub fn stageCell(
        self: *Sidecar,
        cell: usize,
        first_layer: usize,
        last_layer: usize,
        mixing_depth_m: f64,
        mixing_fraction: f64,
        cumulative_layer_bottom_m: []const f64,
        layer_thickness_m: []const f64,
        minimum_layer_thickness_m: f64,
        mixable_before: []const inventory.Storage,
        surface_before: inventory.Storage,
        surface_incorporated: inventory.Storage,
        mixable_after: []const inventory.Storage,
        surface_after: inventory.Storage,
    ) !void {
        if (!self.attempt_active) return error.TillageActivityAttemptNotActive;
        if (cell >= self.cell_count or self.staged_cell[cell]) return error.DuplicateTillageActivityCell;
        const layers = self.layer_capacity;
        if (first_layer > last_layer or last_layer >= layers or cumulative_layer_bottom_m.len != layers or
            layer_thickness_m.len != layers or mixable_before.len != layers or mixable_after.len != layers)
            return error.TillageActivityDimensionMismatch;
        if (!std.math.isFinite(mixing_depth_m) or mixing_depth_m <= 0 or !std.math.isFinite(mixing_fraction) or mixing_fraction < 0 or mixing_fraction > 1 or
            !std.math.isFinite(minimum_layer_thickness_m) or minimum_layer_thickness_m < 0)
            return error.InvalidTillageActivityInput;
        try self.tolerance.validate();
        try surface_before.validate();
        try surface_incorporated.validate();
        try surface_after.validate();
        for (mixable_before) |storage| try storage.validate();
        for (mixable_after) |storage| try storage.validate();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temporary_soil = try arena.allocator().alloc(Record, layers * layers);
        const temporary_surface = try arena.allocator().alloc(Record, layers);
        const predicted = try arena.allocator().dupe(inventory.Storage, mixable_before);
        @memset(temporary_soil, .{});
        @memset(temporary_surface, .{});
        var predicted_surface = surface_before;
        var fi = try arena.allocator().alloc(f64, layers);
        var ti = try arena.allocator().alloc(f64, layers);
        @memset(fi, 0);
        @memset(ti, 0);
        var fi_sum: f64 = 0;
        for (first_layer..last_layer + 1) |layer| {
            const thickness = layer_thickness_m[layer];
            if (!std.math.isFinite(thickness) or thickness <= 0) return error.InvalidTillageActivityInput;
            if (thickness <= minimum_layer_thickness_m) continue;
            const top = cumulative_layer_bottom_m[layer] - thickness;
            const overlap = @max(0, @min(thickness, mixing_depth_m - top));
            fi[layer] = overlap / mixing_depth_m;
            ti[layer] = overlap / thickness;
            fi_sum += fi[layer];
        }
        if (!std.math.isFinite(fi_sum) or fi_sum <= 0 or
            (fi_sum > 1 and !close(self.tolerance, 1, fi_sum)))
            return error.TillageActivityMixingDepthCoverageFailure;

        for (first_layer..last_layer + 1) |donor| {
            for (first_layer..last_layer + 1) |recipient| {
                if (donor == recipient) continue;
                const factor = mixing_fraction * ti[donor] * fi[recipient];
                const record = try scaledRecord(mixable_before[donor], factor);
                temporary_soil[donor * layers + recipient] = record;
                try applyRecord(&predicted[donor], &predicted[recipient], record);
            }
        }
        for (first_layer..last_layer + 1) |recipient| {
            const record = try scaledRecord(surface_incorporated, fi[recipient]);
            temporary_surface[recipient] = record;
            try addRecord(&predicted[recipient], record);
        }
        try subtractStorage(&predicted_surface, surface_incorporated);
        for (predicted, mixable_after) |expected, actual| try requireClose(self.tolerance, expected, actual);
        try requireClose(self.tolerance, predicted_surface, surface_after);

        const soil_base = cell * layers * layers;
        const surface_base = cell * layers;
        @memcpy(self.staged_soil[soil_base .. soil_base + layers * layers], temporary_soil);
        @memcpy(self.staged_surface[surface_base .. surface_base + layers], temporary_surface);
        self.staged_cell[cell] = true;
    }
};

fn scaledRecord(source: inventory.Storage, factor: f64) !Record {
    if (!std.math.isFinite(factor) or factor < 0) return error.InvalidTillageActivityInput;
    var transfer: inventory.Storage = .{};
    var heat_reversed = false;
    inline for (std.meta.fields(inventory.Storage)) |field| {
        const signed = @field(source, field.name) * factor;
        if (!std.math.isFinite(signed)) return error.NonFiniteTillageActivityTransfer;
        if (comptime std.mem.eql(u8, field.name, "heat_megajoules")) {
            @field(transfer, field.name) = @abs(signed);
            heat_reversed = signed < 0;
        } else {
            if (signed < 0) return error.NegativeTillageActivityTransfer;
            @field(transfer, field.name) = signed;
        }
    }
    try transfer.validate();
    return .{ .active = factor != 0 and !std.meta.eql(transfer, inventory.Storage{}), .heat_reversed = heat_reversed, .transfer = transfer };
}

fn applyRecord(donor: *inventory.Storage, recipient: *inventory.Storage, record: Record) !void {
    if (!record.active) return;
    inline for (std.meta.fields(inventory.Storage)) |field| {
        const amount = @field(record.transfer, field.name);
        if (comptime std.mem.eql(u8, field.name, "heat_megajoules")) {
            if (record.heat_reversed) {
                @field(donor, field.name) += amount;
                @field(recipient, field.name) -= amount;
            } else {
                @field(donor, field.name) -= amount;
                @field(recipient, field.name) += amount;
            }
        } else {
            @field(donor, field.name) -= amount;
            @field(recipient, field.name) += amount;
        }
    }
    try donor.validate();
    try recipient.validate();
}

fn addRecord(recipient: *inventory.Storage, record: Record) !void {
    if (!record.active) return;
    inline for (std.meta.fields(inventory.Storage)) |field| {
        const amount = @field(record.transfer, field.name);
        if (comptime std.mem.eql(u8, field.name, "heat_megajoules"))
            @field(recipient, field.name) += if (record.heat_reversed) -amount else amount
        else
            @field(recipient, field.name) += amount;
    }
    try recipient.validate();
}

fn subtractStorage(value: *inventory.Storage, amount: inventory.Storage) !void {
    inline for (std.meta.fields(inventory.Storage)) |field|
        @field(value, field.name) -= @field(amount, field.name);
    try value.validate();
}

fn close(tolerance: Tolerance, expected: f64, actual: f64) bool {
    const scale = @max(@abs(expected), @abs(actual));
    return @abs(actual - expected) <= tolerance.relative * scale +
        @as(f64, @floatFromInt(tolerance.representation_ulps)) * std.math.floatEps(f64) * scale;
}

fn requireClose(tolerance: Tolerance, expected: inventory.Storage, actual: inventory.Storage) !void {
    const expected_values = conservedValues(expected);
    const actual_values = conservedValues(actual);
    const absolute_values = conservedValues(tolerance.absolute);
    for (expected_values, actual_values, absolute_values) |a, b, absolute| {
        const scale = @max(@abs(a), @abs(b));
        const allowed = absolute + tolerance.relative * scale +
            @as(f64, @floatFromInt(tolerance.representation_ulps)) * std.math.floatEps(f64) * scale;
        if (!std.math.isFinite(allowed) or @abs(a - b) > allowed)
            return error.TillageActivityPredictedPostMismatch;
    }
}

/// REDIST may move organic material between residue and SOM labels (notably
/// surface litter -> soil K=4), so only those organic provenance labels are
/// combined. Mineral-N species, gases, phosphate, and plants remain separate;
/// one family cannot conceal a mistranslation in another. `ion_inventory_mol`
/// is diagnostic/non-invariant and is deliberately excluded.
fn conservedValues(value: inventory.Storage) [30]f64 {
    return .{
        value.water_m3,
        value.heat_megajoules,
        value.oxygen_g,
        value.hydrogen_g,
        value.residue_carbon_g + value.organic_carbon_g,
        value.carbon_dioxide_carbon_g,
        value.plant_carbon_g,
        value.residue_nitrogen_g + value.organic_nitrogen_g,
        value.dinitrogen_nitrogen_g,
        value.ammonium_nitrogen_g,
        value.nitrate_nitrogen_g,
        value.plant_nitrogen_g,
        value.residue_phosphorus_g + value.organic_phosphorus_g,
        value.phosphate_phosphorus_g,
        value.plant_phosphorus_g,
        value.aluminum_mol,
        value.iron_mol,
        value.calcium_mol,
        value.magnesium_mol,
        value.sodium_mol,
        value.potassium_mol,
        value.sulfur_mol,
        value.chloride_mol,
        value.silicon_mol,
        value.sand_megagrams,
        value.silt_megagrams,
        value.clay_megagrams,
        value.rock_additive,
        value.cation_exchange_capacity_mol,
        value.anion_exchange_capacity_mol,
    };
}

test "exact REDIST matrix publishes opposing gross paths and surface incorporation" {
    var sidecar = try Sidecar.init(std.testing.allocator, 1, 2, .{ .relative = 64 * std.math.floatEps(f64) });
    defer sidecar.deinit();
    try sidecar.beginAttempt();
    try sidecar.stageCell(0, 0, 1, 0.2, 0.5, &.{ 0.1, 0.2 }, &.{ 0.1, 0.1 }, 0, &.{ .{ .water_m3 = 10 }, .{ .water_m3 = 2 } }, .{ .water_m3 = 3 }, .{ .water_m3 = 2 }, &.{ .{ .water_m3 = 9 }, .{ .water_m3 = 5 } }, .{ .water_m3 = 1 });
    try sidecar.commitAttempt();
    try std.testing.expectEqual(@as(f64, 2.5), (try sidecar.soilRecord(0, 0, 1)).transfer.water_m3);
    try std.testing.expectEqual(@as(f64, 0.5), (try sidecar.soilRecord(0, 1, 0)).transfer.water_m3);
    try std.testing.expectEqual(@as(f64, 1), (try sidecar.surfaceRecord(0, 0)).transfer.water_m3);
    try std.testing.expectEqual(@as(f64, 1), (try sidecar.surfaceRecord(0, 1)).transfer.water_m3);
}

test "negative enthalpy reverses only heat and failed prediction preserves accepted attempt" {
    var sidecar = try Sidecar.init(std.testing.allocator, 1, 2, .{ .relative = 64 * std.math.floatEps(f64) });
    defer sidecar.deinit();
    try sidecar.beginAttempt();
    try sidecar.stageCell(0, 0, 1, 0.2, 0.5, &.{ 0.1, 0.2 }, &.{ 0.1, 0.1 }, 0, &.{ .{ .heat_megajoules = -10 }, .{ .heat_megajoules = -2 } }, .{ .heat_megajoules = -3 }, .{ .heat_megajoules = -2 }, &.{ .{ .heat_megajoules = -9 }, .{ .heat_megajoules = -5 } }, .{ .heat_megajoules = -1 });
    try sidecar.commitAttempt();
    const prior = try sidecar.soilRecord(0, 0, 1);
    try std.testing.expect(prior.heat_reversed);
    try std.testing.expectEqual(@as(f64, 2.5), prior.transfer.heat_megajoules);

    try sidecar.beginAttempt();
    try std.testing.expectError(error.TillageActivityPredictedPostMismatch, sidecar.stageCell(0, 0, 1, 0.2, 0.5, &.{ 0.1, 0.2 }, &.{ 0.1, 0.1 }, 0, &.{ .{ .water_m3 = 10 }, .{ .water_m3 = 2 } }, .{}, .{}, &.{ .{ .water_m3 = 10 }, .{ .water_m3 = 2 } }, .{}));
    sidecar.abortAttempt();
    try std.testing.expectEqualDeep(prior, try sidecar.soilRecord(0, 0, 1));
}

test "sampler excludes the same minimum-thickness layers as REDIST kernels" {
    var sidecar = try Sidecar.init(std.testing.allocator, 1, 2, .{ .relative = 64 * std.math.floatEps(f64) });
    defer sidecar.deinit();
    try sidecar.beginAttempt();
    try sidecar.stageCell(
        0,
        0,
        1,
        0.1005,
        0.5,
        &.{ 0.0005, 0.1005 },
        &.{ 0.0005, 0.1 },
        0.001,
        &.{ .{ .water_m3 = 100 }, .{ .water_m3 = 10 } },
        .{},
        .{},
        &.{ .{ .water_m3 = 100 }, .{ .water_m3 = 10 } },
        .{},
    );
    try sidecar.commitAttempt();
    try std.testing.expect(!(try sidecar.soilRecord(0, 0, 1)).active);
    try std.testing.expect(!(try sidecar.soilRecord(0, 1, 0)).active);
}

test "mineral nitrogen species mismatch cannot hide in total nitrogen" {
    var sidecar = try Sidecar.init(std.testing.allocator, 1, 2, .{ .relative = 64 * std.math.floatEps(f64) });
    defer sidecar.deinit();
    try sidecar.beginAttempt();
    try std.testing.expectError(
        error.TillageActivityPredictedPostMismatch,
        sidecar.stageCell(
            0,
            0,
            1,
            0.2,
            0.5,
            &.{ 0.1, 0.2 },
            &.{ 0.1, 0.1 },
            0,
            &.{
                .{ .ammonium_nitrogen_g = 10 },
                .{ .ammonium_nitrogen_g = 2 },
            },
            .{},
            .{},
            &.{
                .{ .ammonium_nitrogen_g = 8 },
                // The layer total is the correct four grams, but one gram
                // was mistranslated as nitrate and must fail independently.
                .{ .ammonium_nitrogen_g = 3, .nitrate_nitrogen_g = 1 },
            },
            .{},
        ),
    );
    sidecar.abortAttempt();
}

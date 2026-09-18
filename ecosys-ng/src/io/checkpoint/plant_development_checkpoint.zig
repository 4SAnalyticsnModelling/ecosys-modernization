const std = @import("std");
const Phenology = @import("../../plant/lifecycle/phenology.zig").State;
const BranchDevelopment = @import("../../plant/lifecycle/phenology.zig").BranchDevelopmentState;
const Growth = @import("../../plant/lifecycle/growth_stages.zig").State;
const GrowthBranch = @import("../../plant/lifecycle/growth_stages.zig").BranchState;
const Dormancy = @import("../../plant/lifecycle/dormancy.zig").RuntimeState;
const DormancyBranch = @import("../../plant/lifecycle/dormancy.zig").State;

const magic = "ECOSDEVP";
// Version 8 persists branch-local IFLGR and FLGQ end-of-season state.
const version: u32 = 8;
const DormancyBranchV1 = struct {
    accumulated_leafout_h: f64,
    accumulated_leafoff_h: f64,
    lengthening_photoperiod_h: f64,
    shortening_photoperiod_h: f64,
    leafout_disabled: bool,
    leafoff_disabled: bool,
};
const DormancyBranchV7 = struct {
    accumulated_leafout_h: f64,
    accumulated_leafoff_h: f64,
    lengthening_photoperiod_h: f64,
    shortening_photoperiod_h: f64,
    leafout_disabled: bool,
    leafoff_disabled: bool,
    shoot_remobilization_enabled: bool,
    phenological_remobilization_enabled: bool,
    remobilization_elapsed_h: f64,
};

pub const View = struct { phenology: *const Phenology, growth: *const Growth, dormancy: *const Dormancy, branch_development: *const BranchDevelopment };
pub const Limits = struct { maximum_cells: usize, maximum_species: usize, maximum_branches: usize };
pub const Owned = struct {
    phenology: Phenology,
    growth: Growth,
    dormancy: Dormancy,
    branch_development: BranchDevelopment,
    pub fn deinit(self: *Owned) void {
        self.branch_development.deinit();
        self.dormancy.deinit();
        self.growth.deinit();
        self.phenology.deinit();
        self.* = undefined;
    }
};

pub fn write(writer: anytype, view: View) !void {
    try validateView(view);
    try writer.writeAll(magic);
    try writer.writeInt(u32, version, .little);
    try writer.writeInt(u64, @intCast(view.phenology.cell_count), .little);
    try writer.writeInt(u64, @intCast(view.phenology.species_count), .little);
    try writer.writeInt(u64, @intCast(view.growth.plant_count), .little);
    try writer.writeInt(u64, @intCast(view.growth.branches.len), .little);
    for (view.growth.plant_branch_offsets) |value| try writer.writeInt(u64, @intCast(value), .little);
    inline for (@typeInfo(Phenology).@"struct".fields) |field| switch (field.type) {
        []bool => try writeBoolSlice(writer, @field(view.phenology, field.name)),
        []u16 => try writeU16Slice(writer, @field(view.phenology, field.name)),
        []f64 => try writeF64Slice(writer, @field(view.phenology, field.name)),
        else => {},
    };
    for (view.growth.branches) |branch| try writeStruct(writer, branch);
    for (view.dormancy.branches) |branch| try writeStruct(writer, branch);
    inline for (@typeInfo(BranchDevelopment).@"struct".fields) |field| switch (field.type) {
        []f64 => try writeF64Slice(writer, @field(view.branch_development, field.name)),
        []usize => try writeUsizeSlice(writer, @field(view.branch_development, field.name)),
        []u32 => try writeU32Slice(writer, @field(view.branch_development, field.name)),
        []bool => try writeBoolSlice(writer, @field(view.branch_development, field.name)),
        else => {},
    };
}

pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader, limits: Limits) !Owned {
    if (limits.maximum_cells == 0 or limits.maximum_species == 0 or limits.maximum_branches == 0) return error.InvalidPlantDevelopmentCheckpointLimits;
    if (!std.mem.eql(u8, try reader.takeArray(magic.len), magic)) return error.InvalidPlantDevelopmentCheckpointMagic;
    const file_version = try reader.takeInt(u32, .little);
    if (file_version < 1 or file_version > version) return error.UnsupportedPlantDevelopmentCheckpointVersion;
    const cells = try bounded(reader, limits.maximum_cells, error.PlantDevelopmentCheckpointCellLimitExceeded);
    const species = try bounded(reader, limits.maximum_species, error.PlantDevelopmentCheckpointSpeciesLimitExceeded);
    const plants = try bounded(reader, try std.math.mul(usize, limits.maximum_cells, limits.maximum_species), error.PlantDevelopmentCheckpointPlantLimitExceeded);
    const branches = try bounded(reader, limits.maximum_branches, error.PlantDevelopmentCheckpointBranchLimitExceeded);
    if (try std.math.mul(usize, cells, species) != plants) return error.PlantDevelopmentCheckpointDimensionMismatch;
    const counts = try allocator.alloc(usize, plants);
    defer allocator.free(counts);
    var previous: usize = 0;
    for (0..plants + 1) |offset_index| {
        const offset = try readUsize(reader);
        if (offset_index == 0) {
            if (offset != 0) return error.InvalidPlantBranchOffsets;
        } else {
            if (offset < previous or offset > branches) return error.InvalidPlantBranchOffsets;
            counts[offset_index - 1] = offset - previous;
        }
        previous = offset;
    }
    if (previous != branches or branches == 0) return error.InvalidPlantBranchOffsets;
    var phenology = try Phenology.init(allocator, cells, species);
    errdefer phenology.deinit();
    var growth = try Growth.init(allocator, counts);
    errdefer growth.deinit();
    var dormancy = try Dormancy.init(allocator, branches);
    errdefer dormancy.deinit();
    var development = try BranchDevelopment.init(allocator, branches);
    errdefer development.deinit();
    inline for (@typeInfo(Phenology).@"struct".fields) |field| switch (field.type) {
        []bool => if ((file_version >= 3 or (!std.mem.eql(u8, field.name, "emerged") and !std.mem.eql(u8, field.name, "lifecycle_initialized"))) and
            (file_version >= 4 or !std.mem.eql(u8, field.name, "reseed_pending")) and
            (file_version >= 7 or !std.mem.eql(u8, field.name, "death_replant_pending")))
            if (file_version >= 5 or !std.mem.eql(u8, field.name, "leafout_transition_this_step"))
                try readBoolSlice(reader, @field(phenology, field.name)),
        []u16 => if (file_version >= 6) try readU16Slice(reader, @field(phenology, field.name)),
        []f64 => try readF64Slice(reader, @field(phenology, field.name)),
        else => {},
    };
    for (growth.branches) |*branch| branch.* = try readStruct(GrowthBranch, reader);
    for (dormancy.branches) |*branch| {
        if (file_version == 1) {
            const value = try readStruct(DormancyBranchV1, reader);
            branch.* = .{
                .accumulated_leafout_h = value.accumulated_leafout_h,
                .accumulated_leafoff_h = value.accumulated_leafoff_h,
                .lengthening_photoperiod_h = value.lengthening_photoperiod_h,
                .shortening_photoperiod_h = value.shortening_photoperiod_h,
                .leafout_disabled = value.leafout_disabled,
                .leafoff_disabled = value.leafoff_disabled,
            };
        } else if (file_version <= 7) {
            const value = try readStruct(DormancyBranchV7, reader);
            branch.* = .{
                .accumulated_leafout_h = value.accumulated_leafout_h,
                .accumulated_leafoff_h = value.accumulated_leafoff_h,
                .lengthening_photoperiod_h = value.lengthening_photoperiod_h,
                .shortening_photoperiod_h = value.shortening_photoperiod_h,
                .leafout_disabled = value.leafout_disabled,
                .leafoff_disabled = value.leafoff_disabled,
                .shoot_remobilization_enabled = value.shoot_remobilization_enabled,
                .phenological_remobilization_enabled = value.phenological_remobilization_enabled,
                .remobilization_elapsed_h = value.remobilization_elapsed_h,
                .reproductive_growth_disabled = false,
                .reproductive_litterfall_delay_h = 0,
            };
        } else branch.* = try readStruct(DormancyBranch, reader);
    }
    inline for (@typeInfo(BranchDevelopment).@"struct".fields) |field| switch (field.type) {
        []f64 => try readF64Slice(reader, @field(development, field.name)),
        []usize => try readUsizeSlice(reader, @field(development, field.name)),
        []u32 => try readU32Slice(reader, @field(development, field.name)),
        []bool => try readBoolSlice(reader, @field(development, field.name)),
        else => {},
    };
    if (reader.peekByte()) |_| return error.TrailingPlantDevelopmentCheckpointData else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    const result = Owned{ .phenology = phenology, .growth = growth, .dormancy = dormancy, .branch_development = development };
    try validateView(.{ .phenology = &result.phenology, .growth = &result.growth, .dormancy = &result.dormancy, .branch_development = &result.branch_development });
    return result;
}

fn validateView(view: View) !void {
    const plants = try std.math.mul(usize, view.phenology.cell_count, view.phenology.species_count);
    const branches = view.growth.branches.len;
    if (view.growth.plant_count != plants or view.growth.plant_branch_offsets.len != plants + 1 or view.dormancy.branches.len != branches or view.branch_development.branch_count != branches) return error.PlantDevelopmentCheckpointDimensionMismatch;
    if (view.growth.plant_branch_offsets[0] != 0 or view.growth.plant_branch_offsets[plants] != branches) return error.InvalidPlantBranchOffsets;
    for (0..plants) |plant| if (view.growth.plant_branch_offsets[plant] > view.growth.plant_branch_offsets[plant + 1]) return error.InvalidPlantBranchOffsets;
    try view.phenology.validateFinite();
    try view.growth.validateFinite();
    try view.dormancy.validateFinite();
    try view.branch_development.validateFinite();
}

fn bounded(reader: *std.Io.Reader, limit: usize, comptime too_large: anyerror) !usize {
    const value = try reader.takeInt(u64, .little);
    if (value > limit or value > std.math.maxInt(usize)) return too_large;
    return @intCast(value);
}
fn writeF64Slice(writer: anytype, values: []const f64) !void {
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.NonFinitePlantDevelopmentCheckpoint;
        try writer.writeInt(u64, @bitCast(value), .little);
    }
}
fn readF64Slice(reader: *std.Io.Reader, values: []f64) !void {
    for (values) |*value| {
        value.* = @bitCast(try reader.takeInt(u64, .little));
        if (!std.math.isFinite(value.*)) return error.NonFinitePlantDevelopmentCheckpoint;
    }
}
fn writeBoolSlice(writer: anytype, values: []const bool) !void {
    for (values) |value| try writer.writeByte(@intFromBool(value));
}
fn readBoolSlice(reader: *std.Io.Reader, values: []bool) !void {
    for (values) |*value| value.* = switch (try reader.takeByte()) {
        0 => false,
        1 => true,
        else => return error.InvalidPlantDevelopmentBoolean,
    };
}
fn writeUsizeSlice(writer: anytype, values: []const usize) !void {
    for (values) |value| try writer.writeInt(u64, @intCast(value), .little);
}
fn readUsizeSlice(reader: *std.Io.Reader, values: []usize) !void {
    for (values) |*value| value.* = try readUsize(reader);
}
fn readUsize(reader: *std.Io.Reader) !usize {
    const value = try reader.takeInt(u64, .little);
    if (value > std.math.maxInt(usize)) return error.PlantDevelopmentIntegerOverflow;
    return @intCast(value);
}
fn writeU32Slice(writer: anytype, values: []const u32) !void {
    for (values) |value| try writer.writeInt(u32, value, .little);
}
fn readU32Slice(reader: *std.Io.Reader, values: []u32) !void {
    for (values) |*value| value.* = try reader.takeInt(u32, .little);
}
fn writeU16Slice(writer: anytype, values: []const u16) !void {
    for (values) |value| try writer.writeInt(u16, value, .little);
}
fn readU16Slice(reader: *std.Io.Reader, values: []u16) !void {
    for (values) |*value| value.* = try reader.takeInt(u16, .little);
}

fn writeStruct(writer: anytype, value: anytype) !void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| switch (field.type) {
        f64 => {
            const number = @field(value, field.name);
            if (!std.math.isFinite(number)) return error.NonFinitePlantDevelopmentCheckpoint;
            try writer.writeInt(u64, @bitCast(number), .little);
        },
        usize => try writer.writeInt(u64, @intCast(@field(value, field.name)), .little),
        u16 => try writer.writeInt(u16, @field(value, field.name), .little),
        bool => try writer.writeByte(@intFromBool(@field(value, field.name))),
        else => @compileError("unsupported developmental checkpoint field"),
    };
}
fn readStruct(comptime T: type, reader: *std.Io.Reader) !T {
    var value: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| switch (field.type) {
        f64 => {
            @field(value, field.name) = @bitCast(try reader.takeInt(u64, .little));
            if (!std.math.isFinite(@field(value, field.name))) return error.NonFinitePlantDevelopmentCheckpoint;
        },
        usize => @field(value, field.name) = try readUsize(reader),
        u16 => @field(value, field.name) = try reader.takeInt(u16, .little),
        bool => @field(value, field.name) = switch (try reader.takeByte()) {
            0 => false,
            1 => true,
            else => return error.InvalidPlantDevelopmentBoolean,
        },
        else => @compileError("unsupported developmental checkpoint field"),
    };
    return value;
}

test "development checkpoint round trip reconstructs arbitrary species and branches" {
    var phenology = try Phenology.init(std.testing.allocator, 2, 7);
    defer phenology.deinit();
    phenology.active[13] = true;
    phenology.emerged[13] = true;
    phenology.lifecycle_initialized[13] = true;
    phenology.reseed_pending[13] = true;
    phenology.death_replant_pending[13] = true;
    phenology.leafout_transition_this_step[13] = true;
    phenology.replant_day_of_year[13] = 1;
    phenology.replant_year[13] = 2025;
    phenology.initiated_node_count[13] = 8.5;
    const counts = [_]usize{ 1, 2, 1, 3, 1, 1, 2, 1, 1, 1, 1, 1, 1, 2 };
    var growth = try Growth.init(std.testing.allocator, &counts);
    defer growth.deinit();
    growth.branches[3].anthesis_day = 123;
    growth.branches[3].initiated_node_count = 4.5;
    var dormancy = try Dormancy.init(std.testing.allocator, growth.branches.len);
    defer dormancy.deinit();
    dormancy.branches[3].accumulated_leafout_h = 12;
    dormancy.branches[3].shoot_remobilization_enabled = true;
    dormancy.branches[3].phenological_remobilization_enabled = true;
    dormancy.branches[3].remobilization_elapsed_h = 37;
    dormancy.branches[3].reproductive_growth_disabled = true;
    dormancy.branches[3].reproductive_litterfall_delay_h = 239;
    var development = try BranchDevelopment.init(std.testing.allocator, growth.branches.len);
    defer development.deinit();
    development.maturity_group[3] = 8;
    development.stage_day[3 * 10 + 5] = 123;
    development.maximum_concurrently_growing_nodes[3] = 24;
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .phenology = &phenology, .growth = &growth, .dormancy = &dormancy, .branch_development = &development });
    var reader: std.Io.Reader = .fixed(bytes.written());
    var restored = try read(std.testing.allocator, &reader, .{ .maximum_cells = 10, .maximum_species = 20, .maximum_branches = 100 });
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 14), restored.growth.plant_count);
    try std.testing.expectEqual(growth.branches.len, restored.growth.branches.len);
    try std.testing.expect(restored.phenology.active[13]);
    try std.testing.expect(restored.phenology.emerged[13]);
    try std.testing.expect(restored.phenology.lifecycle_initialized[13]);
    try std.testing.expect(restored.phenology.reseed_pending[13]);
    try std.testing.expect(restored.phenology.death_replant_pending[13]);
    try std.testing.expect(restored.phenology.leafout_transition_this_step[13]);
    try std.testing.expectEqual(@as(u16, 1), restored.phenology.replant_day_of_year[13]);
    try std.testing.expectEqual(@as(u16, 2025), restored.phenology.replant_year[13]);
    try std.testing.expectEqual(@as(u16, 123), restored.growth.branches[3].anthesis_day);
    try std.testing.expectEqual(@as(f64, 12), restored.dormancy.branches[3].accumulated_leafout_h);
    try std.testing.expect(restored.dormancy.branches[3].shoot_remobilization_enabled);
    try std.testing.expect(restored.dormancy.branches[3].phenological_remobilization_enabled);
    try std.testing.expectEqual(@as(f64, 37), restored.dormancy.branches[3].remobilization_elapsed_h);
    try std.testing.expect(restored.dormancy.branches[3].reproductive_growth_disabled);
    try std.testing.expectEqual(@as(f64, 239), restored.dormancy.branches[3].reproductive_litterfall_delay_h);
    try std.testing.expectEqual(@as(u32, 123), restored.branch_development.stage_day[35]);
}

test "version seven restart defaults new reproductive turnover state" {
    var phenology = try Phenology.init(std.testing.allocator, 1, 1);
    defer phenology.deinit();
    var growth = try Growth.init(std.testing.allocator, &.{1});
    defer growth.deinit();
    var dormancy = try Dormancy.init(std.testing.allocator, 1);
    defer dormancy.deinit();
    dormancy.branches[0].accumulated_leafout_h = 12;
    dormancy.branches[0].remobilization_elapsed_h = 37;
    var development = try BranchDevelopment.init(std.testing.allocator, 1);
    defer development.deinit();
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();

    try bytes.writer.writeAll(magic);
    try bytes.writer.writeInt(u32, 7, .little);
    try bytes.writer.writeInt(u64, 1, .little);
    try bytes.writer.writeInt(u64, 1, .little);
    try bytes.writer.writeInt(u64, 1, .little);
    try bytes.writer.writeInt(u64, 1, .little);
    for (growth.plant_branch_offsets) |value| try bytes.writer.writeInt(u64, @intCast(value), .little);
    inline for (@typeInfo(Phenology).@"struct".fields) |field| switch (field.type) {
        []bool => try writeBoolSlice(&bytes.writer, @field(phenology, field.name)),
        []u16 => try writeU16Slice(&bytes.writer, @field(phenology, field.name)),
        []f64 => try writeF64Slice(&bytes.writer, @field(phenology, field.name)),
        else => {},
    };
    try writeStruct(&bytes.writer, growth.branches[0]);
    const old = dormancy.branches[0];
    try writeStruct(&bytes.writer, DormancyBranchV7{
        .accumulated_leafout_h = old.accumulated_leafout_h,
        .accumulated_leafoff_h = old.accumulated_leafoff_h,
        .lengthening_photoperiod_h = old.lengthening_photoperiod_h,
        .shortening_photoperiod_h = old.shortening_photoperiod_h,
        .leafout_disabled = old.leafout_disabled,
        .leafoff_disabled = old.leafoff_disabled,
        .shoot_remobilization_enabled = old.shoot_remobilization_enabled,
        .phenological_remobilization_enabled = old.phenological_remobilization_enabled,
        .remobilization_elapsed_h = old.remobilization_elapsed_h,
    });
    inline for (@typeInfo(BranchDevelopment).@"struct".fields) |field| switch (field.type) {
        []f64 => try writeF64Slice(&bytes.writer, @field(development, field.name)),
        []usize => try writeUsizeSlice(&bytes.writer, @field(development, field.name)),
        []u32 => try writeU32Slice(&bytes.writer, @field(development, field.name)),
        []bool => try writeBoolSlice(&bytes.writer, @field(development, field.name)),
        else => {},
    };

    var reader: std.Io.Reader = .fixed(bytes.written());
    var restored = try read(std.testing.allocator, &reader, .{ .maximum_cells = 1, .maximum_species = 1, .maximum_branches = 1 });
    defer restored.deinit();
    try std.testing.expectEqual(@as(f64, 12), restored.dormancy.branches[0].accumulated_leafout_h);
    try std.testing.expectEqual(@as(f64, 37), restored.dormancy.branches[0].remobilization_elapsed_h);
    try std.testing.expect(!restored.dormancy.branches[0].reproductive_growth_disabled);
    try std.testing.expectEqual(@as(f64, 0), restored.dormancy.branches[0].reproductive_litterfall_delay_h);
}

test "development checkpoint enforces runtime branch limit before state allocation" {
    var phenology = try Phenology.init(std.testing.allocator, 1, 1);
    defer phenology.deinit();
    var growth = try Growth.init(std.testing.allocator, &.{2});
    defer growth.deinit();
    var dormancy = try Dormancy.init(std.testing.allocator, 2);
    defer dormancy.deinit();
    var development = try BranchDevelopment.init(std.testing.allocator, 2);
    defer development.deinit();
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .phenology = &phenology, .growth = &growth, .dormancy = &dormancy, .branch_development = &development });
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(error.PlantDevelopmentCheckpointBranchLimitExceeded, read(std.testing.allocator, &reader, .{ .maximum_cells = 1, .maximum_species = 1, .maximum_branches = 1 }));
}

test "development checkpoint rejects trailing corruption" {
    var phenology = try Phenology.init(std.testing.allocator, 1, 1);
    defer phenology.deinit();
    var growth = try Growth.init(std.testing.allocator, &.{1});
    defer growth.deinit();
    var dormancy = try Dormancy.init(std.testing.allocator, 1);
    defer dormancy.deinit();
    var development = try BranchDevelopment.init(std.testing.allocator, 1);
    defer development.deinit();
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try write(&bytes.writer, .{ .phenology = &phenology, .growth = &growth, .dormancy = &dormancy, .branch_development = &development });
    try bytes.writer.writeByte(0xff);
    var reader: std.Io.Reader = .fixed(bytes.written());
    try std.testing.expectError(error.TrailingPlantDevelopmentCheckpointData, read(std.testing.allocator, &reader, .{ .maximum_cells = 1, .maximum_species = 1, .maximum_branches = 2 }));
}

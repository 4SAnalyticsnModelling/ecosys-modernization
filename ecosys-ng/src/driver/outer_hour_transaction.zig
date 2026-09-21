const std = @import("std");
const source_scan = @import("../core/source_scan.zig");
const config_module = @import("../core/config.zig");
const checkpoint = @import("../io/checkpoint/checkpoint.zig");
const bundle_reader = @import("../io/checkpoint/bundle_reader.zig");
const manifest = @import("../io/checkpoint/manifest.zig");
const metadata = @import("../io/checkpoint/plant_checkpoint_metadata.zig");
const development = @import("../io/checkpoint/plant_development_checkpoint.zig");
const roots = @import("../io/checkpoint/plant_root_checkpoint.zig");
const canopy = @import("../io/checkpoint/canopy_state_checkpoint.zig");
const biogeochemistry = @import("../io/checkpoint/soil_biogeochemistry_checkpoint.zig");
const organic = @import("../io/checkpoint/soil_organic_checkpoint.zig");
const transport = @import("../io/checkpoint/transport_state_checkpoint.zig");
const geometry = @import("../io/checkpoint/soil_geometry_checkpoint.zig");
const accounting = @import("../io/checkpoint/plant_accounting_checkpoint.zig");
const mass_balance = @import("../io/checkpoint/landscape_mass_balance_checkpoint.zig");
const GridState = @import("../state/grid.zig").GridState;
const PlantState = @import("../state/grid.zig").PlantState;
const PlantWaterStateUpdate = @import("../plant/state_update/water.zig");
const TillageActivity = @import("../redistribution/tillage/activity.zig");

/// Reusable, memory-only transaction around one fixed external hour. Persistent
/// owners are cloned through their versioned checkpoint codecs and restored by
/// the same validated owner-swap used for restart. Stable transient ledgers and
/// workspaces are journaled separately; no per-hour filesystem checkpoint is
/// created.
pub const Transaction = struct {
    workspace: *Workspace,
    snapshot_index: u1,
    targets: bundle_reader.LiveTargets,
    backup: bundle_reader.OwnedBundle,
    stable: StableJournal,
    active: bool = true,
    promoted_snapshot: bool = false,

    /// Capture a stable, non-owning object graph. Reallocating/checkpoint-owned
    /// roots are automatically excluded and are covered by `backup` instead.
    pub noinline fn captureStable(self: *Transaction, root: anytype, extra_excluded_owners: anytype) !void {
        @setEvalBranchQuota(1_000_000);
        try self.stable.captureReachable(root, self.targets, extra_excluded_owners);
    }

    /// Reuse a validated stable-region layout without recursively reflecting
    /// its object graph again. The source transaction owns only the addresses;
    /// this transaction snapshots the bytes currently resident there, so a
    /// nested stage retry restores its own entry state rather than the outer
    /// hour's earlier entry state. Contract: every destination in this layout
    /// remains allocated and type/tag stable until the nested snapshot is
    /// restored. Newly allocated or tag-activated owned payloads therefore
    /// belong in the checkpoint bundle or a dedicated owner swap, never this
    /// stable journal. The outer capture's exclusion validation establishes
    /// that contract for the hourly production graph.
    pub fn captureCurrentStableLayoutFrom(
        self: *Transaction,
        source: *const Transaction,
    ) !void {
        std.debug.assert(self.active);
        std.debug.assert(source.active);
        std.debug.assert(self != source);
        try self.stable.captureCurrentLayoutFrom(&source.stable);
    }

    pub const FailurePoint = enum { after_canopy_and_management, after_soil_solve };

    /// Test-only late-failure hook. Production builds erase the branch.
    pub fn injectFailureForTest(point: FailurePoint) !void {
        if (comptime @import("builtin").is_test)
            if (testing_failure_point == point) return error.InjectedOuterHourFailure;
    }

    pub fn commit(self: *Transaction) void {
        std.debug.assert(self.active);
        self.active = false;
    }

    pub fn rollback(self: *Transaction) !void {
        if (!self.active) return;
        // Stable destinations still point into the live graph. Restore them
        // before owner-swap moves/deinitializes failed reallocating owners.
        self.stable.restore();
        try bundle_reader.swapIntoLiveForRollback(&self.backup, self.targets);
        self.promoted_snapshot = true;
        self.active = false;
    }

    pub fn deinit(self: *Transaction) void {
        if (self.active) self.rollback() catch @panic("outer-hour rollback validation failed");
        self.stable.deinit();
        self.backup.deinit();
        const workspace = self.workspace;
        workspace.finish(self.snapshot_index, self.promoted_snapshot);
        self.* = undefined;
    }
};

/// Retained memory for consecutive fixed-hour transactions. The first hour
/// sizes the two arenas; subsequent same-or-smaller hours perform no backing
/// allocations. Snapshot owners and codec bytes are kept in separate arenas
/// so serialization scratch never inflates the persistent rollback image.
pub const Workspace = struct {
    backing_allocator: std.mem.Allocator,
    snapshot_arenas: [2]std.heap.ArenaAllocator,
    codec_arena: std.heap.ArenaAllocator,
    snapshot_index: u1 = 0,
    live_index: ?u1 = null,
    in_use: bool = false,

    pub fn init(allocator: std.mem.Allocator) Workspace {
        return .{
            .backing_allocator = allocator,
            .snapshot_arenas = .{ .init(allocator), .init(allocator) },
            .codec_arena = .init(allocator),
        };
    }

    pub fn deinit(self: *Workspace) void {
        std.debug.assert(!self.in_use);
        self.codec_arena.deinit();
        for (self.snapshot_arenas) |arena| arena.deinit();
        self.* = undefined;
    }

    pub fn begin(
        self: *Workspace,
        runtime_config: config_module.SimulationConfig,
        targets: bundle_reader.LiveTargets,
    ) !Transaction {
        if (self.in_use) return error.OuterHourTransactionAlreadyActive;
        std.debug.assert(self.live_index == null or self.snapshot_index != self.live_index.?);
        const snapshot_arena = &self.snapshot_arenas[self.snapshot_index];
        _ = snapshot_arena.reset(.retain_capacity);
        _ = self.codec_arena.reset(.retain_capacity);
        self.in_use = true;
        errdefer {
            self.in_use = false;
            _ = snapshot_arena.reset(.retain_capacity);
            _ = self.codec_arena.reset(.retain_capacity);
        }
        const snapshot_allocator = snapshot_arena.allocator();
        return .{
            .workspace = self,
            .snapshot_index = self.snapshot_index,
            .targets = targets,
            .backup = try cloneBundle(
                snapshot_allocator,
                self.codec_arena.allocator(),
                runtime_config,
                targets,
            ),
            .stable = .{ .allocator = snapshot_allocator },
        };
    }

    pub fn retainedCapacity(self: *const Workspace) usize {
        var capacity = self.codec_arena.queryCapacity();
        for (self.snapshot_arenas) |arena| capacity += arena.queryCapacity();
        return capacity;
    }

    fn finish(self: *Workspace, completed_snapshot_index: u1, promoted_snapshot: bool) void {
        std.debug.assert(self.in_use);
        std.debug.assert(completed_snapshot_index == self.snapshot_index);
        if (promoted_snapshot) {
            // Rollback swapped this arena's owners into the live model. Keep
            // its address and allocations intact. The prior live arena, if
            // any, was swapped into `backup` and deinitialized before here.
            if (self.live_index) |old_live_index| {
                std.debug.assert(old_live_index != completed_snapshot_index);
                _ = self.snapshot_arenas[old_live_index].reset(.retain_capacity);
            }
            self.live_index = completed_snapshot_index;
            self.snapshot_index = completed_snapshot_index ^ 1;
        }
        self.in_use = false;
    }
};

pub var testing_failure_point: ?Transaction.FailurePoint = null;

/// Exact owner-swap guard for additional topology-dependent owners that are
/// intentionally outside the restart bundle (for example the hourly canopy
/// carbon-exchange ledger). `backup` must be a deep clone.
pub fn OwnerSwap(comptime T: type) type {
    return struct {
        live: *T,
        backup: T,
        active: bool = true,

        pub fn begin(live: *T, backup: T) @This() {
            return .{ .live = live, .backup = backup };
        }
        pub fn commit(self: *@This()) void {
            std.debug.assert(self.active);
            self.active = false;
        }
        pub fn rollback(self: *@This()) void {
            if (!self.active) return;
            std.mem.swap(T, self.live, &self.backup);
            self.active = false;
        }
        pub fn deinit(self: *@This()) void {
            if (self.active) self.rollback();
            self.backup.deinit();
            self.* = undefined;
        }
    };
}

/// Retained arena for a topology-dependent owner kept outside the restart
/// bundle. The owner-specific clone function remains authoritative; only its
/// allocation backing is recycled between accepted hours.
pub fn OwnerWorkspace(comptime T: type) type {
    return struct {
        backing_allocator: std.mem.Allocator,
        arenas: [2]std.heap.ArenaAllocator,
        snapshot_index: u1 = 0,
        live_index: ?u1 = null,
        in_use: bool = false,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .backing_allocator = allocator, .arenas = .{ .init(allocator), .init(allocator) } };
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(!self.in_use);
            for (self.arenas) |arena| arena.deinit();
            self.* = undefined;
        }

        pub fn begin(
            self: *Self,
            live: *T,
            comptime clone_owner: anytype,
        ) !ReusableOwnerSwap(T) {
            if (self.in_use) return error.OuterHourOwnerTransactionAlreadyActive;
            std.debug.assert(self.live_index == null or self.snapshot_index != self.live_index.?);
            const snapshot_arena = &self.arenas[self.snapshot_index];
            _ = snapshot_arena.reset(.retain_capacity);
            self.in_use = true;
            errdefer self.in_use = false;
            return .{
                .workspace = self,
                .snapshot_index = self.snapshot_index,
                .live = live,
                .backup = try clone_owner(live, snapshot_arena.allocator()),
            };
        }

        pub fn retainedCapacity(self: *const Self) usize {
            var capacity: usize = 0;
            for (self.arenas) |arena| capacity += arena.queryCapacity();
            return capacity;
        }

        fn finish(self: *Self, completed_snapshot_index: u1, promoted_snapshot: bool) void {
            std.debug.assert(self.in_use);
            std.debug.assert(completed_snapshot_index == self.snapshot_index);
            if (promoted_snapshot) {
                if (self.live_index) |old_live_index| {
                    std.debug.assert(old_live_index != completed_snapshot_index);
                    _ = self.arenas[old_live_index].reset(.retain_capacity);
                }
                self.live_index = completed_snapshot_index;
                self.snapshot_index = completed_snapshot_index ^ 1;
            }
            self.in_use = false;
        }
    };
}

pub fn ReusableOwnerSwap(comptime T: type) type {
    return struct {
        workspace: *OwnerWorkspace(T),
        snapshot_index: u1,
        live: *T,
        backup: T,
        active: bool = true,
        promoted_snapshot: bool = false,

        pub fn commit(self: *@This()) void {
            std.debug.assert(self.active);
            self.active = false;
        }
        pub fn rollback(self: *@This()) void {
            if (!self.active) return;
            std.mem.swap(T, self.live, &self.backup);
            self.promoted_snapshot = true;
            self.active = false;
        }
        pub fn deinit(self: *@This()) void {
            if (self.active) self.rollback();
            self.backup.deinit();
            self.workspace.finish(self.snapshot_index, self.promoted_snapshot);
            self.* = undefined;
        }
    };
}

const Segment = struct {
    destination: []u8,
    before: []u8,
};

const AddressRange = struct {
    first: usize,
    end: usize,
};

const ExcludedRanges = struct {
    allocator: std.mem.Allocator,
    ranges: std.ArrayList(AddressRange) = .empty,
    covers_all: bool = false,

    fn deinit(self: *ExcludedRanges) void {
        self.ranges.deinit(self.allocator);
        self.* = undefined;
    }

    fn appendBytes(self: *ExcludedRanges, bytes: []const u8) !void {
        if (bytes.len == 0 or self.covers_all) return;
        const first = @intFromPtr(bytes.ptr);
        const end = std.math.add(usize, first, bytes.len) catch {
            self.covers_all = true;
            self.ranges.clearRetainingCapacity();
            return;
        };
        try self.ranges.append(self.allocator, .{ .first = first, .end = end });
    }

    fn finish(self: *ExcludedRanges) void {
        if (self.covers_all or self.ranges.items.len < 2) return;
        std.sort.pdq(AddressRange, self.ranges.items, {}, struct {
            fn lessThan(_: void, left: AddressRange, right: AddressRange) bool {
                return left.first < right.first or
                    (left.first == right.first and left.end < right.end);
            }
        }.lessThan);
        var retained: usize = 1;
        for (self.ranges.items[1..]) |candidate| {
            const current = &self.ranges.items[retained - 1];
            if (candidate.first <= current.end) {
                current.end = @max(current.end, candidate.end);
            } else {
                self.ranges.items[retained] = candidate;
                retained += 1;
            }
        }
        self.ranges.items.len = retained;
    }

    fn overlaps(self: *const ExcludedRanges, candidate: []const u8) bool {
        if (candidate.len == 0) return false;
        if (self.covers_all) return true;
        const first = @intFromPtr(candidate.ptr);
        const end = std.math.add(usize, first, candidate.len) catch return true;
        var lower: usize = 0;
        var upper = self.ranges.items.len;
        while (lower < upper) {
            const middle = lower + (upper - lower) / 2;
            if (self.ranges.items[middle].end <= first) {
                lower = middle + 1;
            } else {
                upper = middle;
            }
        }
        return lower < self.ranges.items.len and self.ranges.items[lower].first < end;
    }
};

const StableJournal = struct {
    allocator: std.mem.Allocator,
    segments: std.ArrayList(Segment) = .empty,

    noinline fn captureReachable(self: *StableJournal, root: anytype, targets: bundle_reader.LiveTargets, extra: anytype) !void {
        const Root = @TypeOf(root);
        comptime if (@typeInfo(Root) != .pointer or @typeInfo(Root).pointer.size != .one)
            @compileError("stable journal root must be a single-item pointer");
        var excluded_ranges: ExcludedRanges = .{ .allocator = self.allocator };
        defer excluded_ranges.deinit();
        try collectExcludedRanges(&excluded_ranges, targets, extra);
        excluded_ranges.finish();
        try visit(self, root, &excluded_ranges, targets, extra);
    }

    /// Copy current bytes for an already validated set of stable destinations.
    /// Deliberately non-generic: nested transactions must not instantiate the
    /// full reachable-graph visitor a second time merely to reuse its layout.
    fn captureCurrentLayoutFrom(self: *StableJournal, source: *const StableJournal) !void {
        for (source.segments.items) |segment|
            try self.appendBytes(segment.destination);
    }

    fn restore(self: *StableJournal) void {
        var index = self.segments.items.len;
        while (index > 0) {
            index -= 1;
            const segment = self.segments.items[index];
            @memcpy(segment.destination, segment.before);
        }
    }

    fn deinit(self: *StableJournal) void {
        for (self.segments.items) |segment| self.allocator.free(segment.before);
        self.segments.deinit(self.allocator);
        self.* = undefined;
    }

    fn appendBytes(self: *StableJournal, destination: []u8) !void {
        if (destination.len == 0) return;
        const before = try self.allocator.dupe(u8, destination);
        errdefer self.allocator.free(before);
        try self.segments.append(self.allocator, .{ .destination = destination, .before = before });
    }
};

// This visitor deliberately remains a family of small type-specialized
// functions. ReleaseFast otherwise recursively inlines hundreds of reflected
// field walkers into one very large optimization unit. `noinline` changes only
// code generation; declaration-order traversal and error propagation remain
// identical.
noinline fn visit(journal: *StableJournal, pointer: anytype, excluded_ranges: *const ExcludedRanges, targets: bundle_reader.LiveTargets, extra: anytype) !void {
    const Pointer = @TypeOf(pointer);
    const T = @typeInfo(Pointer).pointer.child;
    if (T == std.mem.Allocator) return;
    switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => try journal.appendBytes(std.mem.asBytes(pointer)),
        .array => |array_info| {
            if (!containsPointers(array_info.child)) {
                try journal.appendBytes(std.mem.asBytes(pointer));
            } else {
                for (pointer) |*element| try visit(journal, element, excluded_ranges, targets, extra);
            }
        },
        .@"struct" => |struct_info| inline for (struct_info.fields) |field| {
            if (field.type == std.mem.Allocator) continue;
            try visit(journal, &@field(pointer.*, field.name), excluded_ranges, targets, extra);
        },
        .optional => {
            // The tag/representation is state too. In particular, the first
            // failed hour changes resolved_development_year from null to a
            // value; restoring only a present payload cannot recover null.
            try journal.appendBytes(std.mem.asBytes(pointer));
            if (pointer.*) |*payload| try visit(journal, payload, excluded_ranges, targets, extra);
        },
        .pointer => |pointer_info| switch (pointer_info.size) {
            .slice => if (!pointer_info.is_const) {
                const bytes = std.mem.sliceAsBytes(pointer.*);
                if (!excluded_ranges.overlaps(bytes)) {
                    try journal.appendBytes(bytes);
                    if (comptime containsPointers(pointer_info.child))
                        for (pointer.*) |*element| try visit(journal, element, excluded_ranges, targets, extra);
                }
            },
            .one => if (!pointer_info.is_const and @typeInfo(pointer_info.child) != .@"opaque") {
                const address = @intFromPtr(pointer.*);
                const pointee = std.mem.asBytes(pointer.*);
                if (!isExcludedOwner(address, targets, extra) and
                    !excluded_ranges.overlaps(pointee))
                    try visit(journal, pointer.*, excluded_ranges, targets, extra);
            },
            else => {},
        },
        .@"union" => |union_info| {
            // Preserve the tag/representation and journal any nested active
            // slice so optional/union wrappers cannot hide an owner alias.
            try journal.appendBytes(std.mem.asBytes(pointer));
            if (union_info.tag_type != null) switch (pointer.*) {
                inline else => |*payload| try visit(journal, payload, excluded_ranges, targets, extra),
            };
        },
        .vector => try journal.appendBytes(std.mem.asBytes(pointer)),
        else => {},
    }
}

noinline fn collectExcludedRanges(excluded_ranges: *ExcludedRanges, targets: bundle_reader.LiveTargets, extra: anytype) !void {
    inline for (.{
        targets.grid,
        targets.plants,
        targets.plant_development.phenology,
        targets.plant_development.growth,
        targets.plant_development.dormancy,
        targets.plant_development.branch_development,
        targets.plant_roots,
        targets.plant_canopy.canopy,
        targets.plant_canopy.retention,
        targets.plant_canopy.layer_distribution,
        targets.soil_biogeochemistry.microbial,
        targets.soil_biogeochemistry.microbial_thermal_adaptation,
        targets.soil_biogeochemistry.chemistry,
        targets.soil_biogeochemistry.available_nutrients,
        targets.soil_biogeochemistry.fertilizer,
        targets.soil_biogeochemistry.mineral_fertilizer,
        targets.soil_biogeochemistry.fertilizer_band,
        targets.soil_biogeochemistry.reactive_nitrogen,
        targets.soil_biogeochemistry.microbial_phosphorus,
        targets.soil_biogeochemistry.nutrient_competition,
        targets.soil_organic_matter.profile,
        targets.soil_organic_matter.surface,
        targets.soil_organic_matter.litter_chemistry,
        targets.soil_organic_matter.litter_fertilizer,
        targets.soil_organic_matter.surface_respiration,
        targets.soil_organic_matter.surface_autotrophic,
        targets.soil_organic_matter.surface_denitrification,
        targets.soil_organic_matter.surface_fire_exchange,
        targets.soil_organic_matter.litter_salt_ingress,
        targets.transport.micropore,
        targets.transport.macropore,
        targets.transport.mineral_nitrogen,
        targets.transport.organic,
        targets.transport.gas,
        targets.transport.litter_gas,
        targets.transport.snow,
        targets.transport.surface,
        targets.soil_geometry_and_hydrology.geometry,
        targets.soil_geometry_and_hydrology.hydrology,
        targets.soil_geometry_and_hydrology.surface,
        targets.soil_geometry_and_hydrology.erosion,
        targets.soil_geometry_and_hydrology.suspended,
        targets.soil_geometry_and_hydrology.climate,
        targets.soil_geometry_and_hydrology.eroded_minerals,
        targets.soil_geometry_and_hydrology.surface_litter_geometry,
        targets.landscape_mass_balance,
        targets.plant_accounting.daily_flux,
        targets.plant_accounting.root_soil_exchange,
    }) |owner| try collectReachableRanges(excluded_ranges, owner.*);
    if (targets.soil_geometry_and_hydrology.runtime) |runtime| inline for (.{ runtime.soil_properties, runtime.soil_thermal }) |owner|
        try collectReachableRanges(excluded_ranges, owner.*);
    if (targets.soil_geometry_and_hydrology.surface_boundary) |surface| inline for (.{ surface.ground_air, surface.surface_aerodynamics, surface.atmospheric_carrier }) |owner|
        try collectReachableRanges(excluded_ranges, owner.*);
    if (targets.soil_geometry_and_hydrology.water_table) |water_table|
        try collectReachableRanges(excluded_ranges, water_table.topology.*);
    inline for (.{
        targets.soil_geometry_and_hydrology.surface_litter_ice_m3,
        targets.soil_geometry_and_hydrology.delayed_live_canopy_combustion_heat_megajoules,
        targets.soil_geometry_and_hydrology.delayed_standing_dead_combustion_heat_megajoules,
        targets.soil_geometry_and_hydrology.delayed_subsurface_combustion_heat_megajoules,
        targets.soil_geometry_and_hydrology.delayed_root_uptake_heat_megajoules,
        targets.soil_geometry_and_hydrology.delayed_surface_combustion_heat_megajoules,
        targets.plant_accounting.cumulative_harvest_salt_mol_by_plant,
        targets.plant_accounting.cumulative_water_source_m3_by_plant,
    }) |owned_slice| try excluded_ranges.appendBytes(std.mem.sliceAsBytes(owned_slice));
    // Extra roots can themselves own reallocating storage (notably the
    // topology-sized canopy carbon-exchange state). Excluding only the root
    // address is insufficient when another context contains a direct alias to
    // one of its slices, so exclude every backing range reachable from it.
    inline for (extra) |owner| try collectReachableRanges(excluded_ranges, owner.*);
}

// Build the immutable owner-range index once per root capture. The former
// predicate recursively traversed every checkpoint owner for every mutable
// slice in the hourly context, multiplying identical ownership work by the
// context's hundreds of aliases.
noinline fn collectReachableRanges(excluded_ranges: *ExcludedRanges, value: anytype) !void {
    const T = @TypeOf(value);
    if (T == std.mem.Allocator or comptime !containsPointers(T)) return;
    switch (@typeInfo(T)) {
        .pointer => |pointer_info| switch (pointer_info.size) {
            .slice => {
                try excluded_ranges.appendBytes(std.mem.sliceAsBytes(value));
                if (comptime containsPointers(pointer_info.child))
                    for (value) |element| try collectReachableRanges(excluded_ranges, element);
            },
            // Checkpoint owners use slices for allocation. Do not follow
            // allocator/vtable or borrowed single-item pointers.
            else => {},
        },
        .array => |array_info| if (comptime containsPointers(array_info.child))
            for (value) |element| try collectReachableRanges(excluded_ranges, element),
        .@"struct" => |struct_info| inline for (struct_info.fields) |field| {
            if (field.type != std.mem.Allocator and comptime containsPointers(field.type))
                try collectReachableRanges(excluded_ranges, @field(value, field.name));
        },
        .optional => if (value) |payload| try collectReachableRanges(excluded_ranges, payload),
        .@"union" => |union_info| if (union_info.tag_type != null) switch (value) {
            inline else => |payload| try collectReachableRanges(excluded_ranges, payload),
        },
        else => {},
    }
}

noinline fn rangeTouchesReachable(candidate: []u8, pointer: anytype) bool {
    const Pointer = @TypeOf(pointer);
    comptime if (@typeInfo(Pointer) != .pointer or @typeInfo(Pointer).pointer.size != .one)
        @compileError("checkpoint owner range root must be a single-item pointer");
    return valueTouchesRange(candidate, pointer.*);
}

// Keep recursive specializations isolated for the same reason as `visit`.
// This path is an ownership/alias predicate, not numerical model science.
noinline fn valueTouchesRange(candidate: []u8, value: anytype) bool {
    const T = @TypeOf(value);
    if (T == std.mem.Allocator) return false;
    return switch (@typeInfo(T)) {
        .pointer => |pointer_info| switch (pointer_info.size) {
            .slice => blk: {
                if (rangesOverlap(candidate, std.mem.sliceAsBytes(@constCast(value)))) break :blk true;
                if (comptime containsPointers(pointer_info.child))
                    for (value) |element| if (valueTouchesRange(candidate, element)) break :blk true;
                break :blk false;
            },
            // Checkpoint owners use slices for allocation. Do not follow
            // allocator/vtable or borrowed single-item pointers.
            else => false,
        },
        .array => blk: {
            for (value) |element| if (valueTouchesRange(candidate, element)) break :blk true;
            break :blk false;
        },
        .@"struct" => |struct_info| blk: {
            inline for (struct_info.fields) |field| if (valueTouchesRange(candidate, @field(value, field.name))) break :blk true;
            break :blk false;
        },
        .optional => if (value) |payload| valueTouchesRange(candidate, payload) else false,
        .@"union" => |union_info| if (union_info.tag_type != null) switch (value) {
            inline else => |payload| valueTouchesRange(candidate, payload),
        } else false,
        else => false,
    };
}

fn rangesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_first = @intFromPtr(a.ptr);
    const b_first = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_first, a.len) catch return true;
    const b_end = std.math.add(usize, b_first, b.len) catch return true;
    return a_first < b_end and b_first < a_end;
}

test "owned-range recursion preserves nested declaration traversal semantics" {
    const Tagged = union(enum) {
        inactive: void,
        active: struct { nested: [2][]u8 },
    };
    const Nested = struct {
        direct: []u8,
        optional: ?struct { values: []u16 },
        tagged: Tagged,
        borrowed: *u8,
    };

    var direct = [_]u8{ 1, 2, 3, 4 };
    var optional = [_]u16{ 5, 6, 7 };
    var first = [_]u8{ 8, 9 };
    var second = [_]u8{ 10, 11, 12 };
    var borrowed: u8 = 13;
    const nested: Nested = .{
        .direct = &direct,
        .optional = .{ .values = &optional },
        .tagged = .{ .active = .{ .nested = .{ &first, &second } } },
        .borrowed = &borrowed,
    };

    try std.testing.expect(valueTouchesRange(direct[1..3], nested));
    try std.testing.expect(valueTouchesRange(std.mem.sliceAsBytes(optional[2..3]), nested));
    try std.testing.expect(valueTouchesRange(second[0..1], nested));
    // Checkpoint owners intentionally expose allocation through slices. A
    // borrowed single-item pointer must not be followed by this predicate.
    try std.testing.expect(!valueTouchesRange(std.mem.asBytes(&borrowed), nested));
}

test "range overlap predicate matches bounded interval model" {
    var bytes: [64]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x6f757465725f686f);
    const random = prng.random();
    for (0..4096) |_| {
        const a_start = random.uintLessThan(usize, bytes.len + 1);
        const b_start = random.uintLessThan(usize, bytes.len + 1);
        const a_len = random.uintLessThan(usize, bytes.len - a_start + 1);
        const b_len = random.uintLessThan(usize, bytes.len - b_start + 1);
        const expected = a_len != 0 and b_len != 0 and
            a_start < b_start + b_len and b_start < a_start + a_len;
        try std.testing.expectEqual(
            expected,
            rangesOverlap(bytes[a_start..][0..a_len], bytes[b_start..][0..b_len]),
        );
    }
}

fn containsPointers(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer, .optional, .@"union" => true,
        .array => |info| containsPointers(info.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| if (containsPointers(field.type)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

noinline fn isExcludedOwner(address: usize, targets: bundle_reader.LiveTargets, extra: anytype) bool {
    inline for (extra) |candidate| if (address == @intFromPtr(candidate)) return true;
    inline for (.{
        targets.grid,
        targets.plants,
        targets.plant_development.phenology,
        targets.plant_development.growth,
        targets.plant_development.dormancy,
        targets.plant_development.branch_development,
        targets.plant_roots,
        targets.plant_canopy.canopy,
        targets.plant_canopy.retention,
        targets.plant_canopy.layer_distribution,
        targets.soil_biogeochemistry.microbial,
        targets.soil_biogeochemistry.microbial_thermal_adaptation,
        targets.soil_biogeochemistry.chemistry,
        targets.soil_biogeochemistry.available_nutrients,
        targets.soil_biogeochemistry.fertilizer,
        targets.soil_biogeochemistry.mineral_fertilizer,
        targets.soil_biogeochemistry.fertilizer_band,
        targets.soil_biogeochemistry.reactive_nitrogen,
        targets.soil_biogeochemistry.microbial_phosphorus,
        targets.soil_biogeochemistry.nutrient_competition,
        targets.soil_organic_matter.profile,
        targets.soil_organic_matter.surface,
        targets.soil_organic_matter.litter_chemistry,
        targets.soil_organic_matter.litter_fertilizer,
        targets.soil_organic_matter.surface_respiration,
        targets.soil_organic_matter.surface_autotrophic,
        targets.soil_organic_matter.surface_denitrification,
        targets.soil_organic_matter.surface_fire_exchange,
        targets.soil_organic_matter.litter_salt_ingress,
        targets.transport.micropore,
        targets.transport.macropore,
        targets.transport.mineral_nitrogen,
        targets.transport.organic,
        targets.transport.gas,
        targets.transport.litter_gas,
        targets.transport.snow,
        targets.transport.surface,
        targets.soil_geometry_and_hydrology.geometry,
        targets.soil_geometry_and_hydrology.hydrology,
        targets.soil_geometry_and_hydrology.surface,
        targets.soil_geometry_and_hydrology.erosion,
        targets.soil_geometry_and_hydrology.suspended,
        targets.soil_geometry_and_hydrology.climate,
        targets.soil_geometry_and_hydrology.eroded_minerals,
        targets.soil_geometry_and_hydrology.surface_litter_geometry,
        targets.landscape_mass_balance,
        targets.plant_accounting.daily_flux,
        targets.plant_accounting.root_soil_exchange,
    }) |candidate| if (address == @intFromPtr(candidate)) return true;
    if (targets.soil_geometry_and_hydrology.runtime) |runtime| inline for (.{ runtime.soil_properties, runtime.soil_thermal }) |candidate|
        if (address == @intFromPtr(candidate)) return true;
    if (targets.soil_geometry_and_hydrology.surface_boundary) |surface| inline for (.{ surface.ground_air, surface.surface_aerodynamics, surface.atmospheric_carrier }) |candidate|
        if (address == @intFromPtr(candidate)) return true;
    if (targets.soil_geometry_and_hydrology.water_table) |water_table|
        if (address == @intFromPtr(water_table.topology)) return true;
    return false;
}

fn cloneBundle(
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    runtime_config: config_module.SimulationConfig,
    targets: bundle_reader.LiveTargets,
) !bundle_reader.OwnedBundle {
    var codec_bytes: std.Io.Writer.Allocating = .init(scratch_allocator);
    defer codec_bytes.deinit();
    const shape: manifest.RuntimeShape = .{
        .columns = targets.transport.surface.columns,
        .rows = targets.transport.surface.rows,
        .soil_layers = targets.grid.soil_layer_capacity,
        .snow_layers = targets.transport.snow.layer_capacity,
        .plant_species_per_cell = targets.plants.species_count,
        .root_axes_per_plant = targets.plant_roots.root_axis_count,
    };
    var grid = try GridState.init(allocator, runtime_config);
    errdefer grid.deinit();
    var plants = try PlantState.init(allocator, runtime_config);
    errdefer plants.deinit();
    {
        codec_bytes.clearRetainingCapacity();
        try checkpoint.writeCoupled(&codec_bytes.writer, targets.grid.*, targets.plants.*);
        var reader = std.Io.Reader.fixed(codec_bytes.written());
        try checkpoint.readCoupledInto(&reader, &grid, &plants);
        // The coupled format predates the source NJ rooting bound. It is an
        // authoritative grid field, so retain it exactly in the memory clone.
        @memcpy(grid.maximum_rooting_layer_count, targets.grid.maximum_rooting_layer_count);
    }

    var plant_development = try cloneSection(development, allocator, &codec_bytes, targets.plant_development, .{
        .maximum_cells = targets.plant_development.phenology.cell_count,
        .maximum_species = targets.plant_development.phenology.species_count,
        .maximum_branches = targets.plant_development.growth.branches.len,
    });
    errdefer plant_development.deinit();
    var plant_roots = try cloneRootSection(allocator, &codec_bytes, targets.plant_roots.*);
    errdefer plant_roots.deinit();
    const canopy_state = targets.plant_canopy.canopy;
    var plant_canopy = try cloneSection(canopy, allocator, &codec_bytes, targets.plant_canopy, .{
        .maximum_cells = canopy_state.cell_count,
        .maximum_species = canopy_state.species_count,
        .maximum_branches = canopy_state.branch_node_offsets.len - 1,
        .maximum_nodes = canopy_state.node_sample_offsets.len - 1,
        .maximum_samples = canopy_state.node_sample_offsets[canopy_state.node_sample_offsets.len - 1],
        .maximum_layers = targets.plant_canopy.layer_distribution.layer_count,
        .maximum_inclinations = targets.plant_canopy.layer_distribution.inclination_count,
        .maximum_azimuths = targets.plant_canopy.layer_distribution.azimuth_count,
    });
    errdefer plant_canopy.deinit();
    const microbial = targets.soil_biogeochemistry.microbial;
    var soil_biogeochemistry = try cloneSection(biogeochemistry, allocator, &codec_bytes, targets.soil_biogeochemistry, .{
        .maximum_cells = microbial.cell_count,
        .maximum_layers = microbial.layer_count,
        .maximum_substrates = microbial.substrate_count,
        .maximum_populations = microbial.population_count,
    });
    errdefer soil_biogeochemistry.deinit();
    var soil_organic_matter = try cloneSection(organic, allocator, &codec_bytes, targets.soil_organic_matter, .{
        .maximum_profile_layers = targets.soil_organic_matter.profile.layer_count,
        .maximum_surface_cells = targets.soil_organic_matter.surface.layer_count,
    });
    errdefer soil_organic_matter.deinit();
    var transport_state = try cloneSection(transport, allocator, &codec_bytes, targets.transport, .{
        .maximum_transport_cells = targets.transport.micropore.cell_count,
        .maximum_solute_species = targets.transport.micropore.species_count,
        .maximum_snow_cells = targets.transport.snow.cell_count,
        .maximum_snow_layers = targets.transport.snow.layer_capacity,
    });
    errdefer transport_state.deinit();
    // Restart intentionally clears chemistry-derived aqueous NH3. An hourly
    // rollback must instead be bit-exact, because retry resumes before the
    // rebuild point. Overlay both gas owners from the accepted live state.
    exactCopyGas(&transport_state.gas, targets.transport.gas);
    exactCopyGas(&transport_state.litter_gas, targets.transport.litter_gas);
    var geometry_state = try cloneSection(geometry, allocator, &codec_bytes, targets.soil_geometry_and_hydrology, .{
        .maximum_columns = shape.columns,
        .maximum_rows = shape.rows,
        .maximum_soil_layers = shape.soil_layers,
        .maximum_snow_layers = shape.snow_layers,
        .maximum_plants = targets.plant_roots.plant_count,
    });
    errdefer geometry_state.deinit();
    var plant_accounting = try cloneAccounting(allocator, &codec_bytes, targets.plant_accounting);
    errdefer plant_accounting.deinit();
    var landscape_mass_balance = try cloneMassBalance(
        allocator,
        &codec_bytes,
        targets.landscape_mass_balance.*,
        .{
            .cell_count = try std.math.mul(usize, shape.columns, shape.rows),
            .soil_layer_capacity = shape.soil_layers,
            .snow_layer_capacity = shape.snow_layers,
        },
    );
    errdefer landscape_mass_balance.deinit();
    const transaction_output_root = try allocator.dupe(
        u8,
        if (@import("builtin").os.tag == .windows)
            "C:\\ecosys-ng-in-memory-hour-transaction"
        else
            "/ecosys-ng-in-memory-hour-transaction",
    );
    errdefer allocator.free(transaction_output_root);
    const manifest_entries = try allocator.alloc(manifest.Entry, 0);
    errdefer allocator.free(manifest_entries);
    const metadata_cells = try allocator.alloc(metadata.OwnedCell, 0);
    errdefer allocator.free(metadata_cells);

    return .{
        .manifest = .{
            .allocator = allocator,
            .generation = 1,
            .instant = .{ .year = 1, .day_of_year = 1, .hour = 0 },
            .output = .{
                .canonical_root = transaction_output_root,
                .run_identity = 1,
                .fingerprint = manifest.outputIdentityFingerprint(1, transaction_output_root),
            },
            .shape = shape,
            .entries = manifest_entries,
        },
        .grid = grid,
        .plants = plants,
        .plant_metadata = .{
            .allocator = allocator,
            .day_of_year = 1,
            .year = 1,
            .cells = metadata_cells,
        },
        .plant_development = plant_development,
        .plant_roots = plant_roots,
        .plant_canopy = plant_canopy,
        .soil_biogeochemistry = soil_biogeochemistry,
        .soil_organic_matter = soil_organic_matter,
        .transport = transport_state,
        .soil_geometry_and_hydrology = geometry_state,
        .landscape_mass_balance = landscape_mass_balance,
        .plant_accounting = plant_accounting,
    };
}

fn exactCopyGas(destination: *@import("../soil/gas/transport.zig").State, source: *const @import("../soil/gas/transport.zig").State) void {
    inline for (@typeInfo(@import("../soil/gas/transport.zig").State).@"struct".fields) |field|
        if (field.type == []f64) @memcpy(@field(destination, field.name), @field(source, field.name));
}

fn cloneSection(comptime module: type, allocator: std.mem.Allocator, bytes: *std.Io.Writer.Allocating, view: module.View, limits: module.Limits) !module.Owned {
    bytes.clearRetainingCapacity();
    try module.write(&bytes.writer, view);
    var reader = std.Io.Reader.fixed(bytes.written());
    return module.read(allocator, &reader, limits);
}

fn cloneRootSection(allocator: std.mem.Allocator, bytes: *std.Io.Writer.Allocating, state: @import("../plant/root/plant_root_system.zig").State) !@import("../plant/root/plant_root_system.zig").State {
    bytes.clearRetainingCapacity();
    try roots.write(&bytes.writer, state);
    var reader = std.Io.Reader.fixed(bytes.written());
    return roots.read(allocator, &reader, .{
        .maximum_plants = state.plant_count,
        .maximum_soil_layers = state.soil_layer_count,
        .maximum_root_axes = state.root_axis_count,
    });
}

fn cloneAccounting(allocator: std.mem.Allocator, bytes: *std.Io.Writer.Allocating, view: accounting.View) !accounting.Owned {
    bytes.clearRetainingCapacity();
    try accounting.write(&bytes.writer, view);
    var reader = std.Io.Reader.fixed(bytes.written());
    return accounting.read(allocator, &reader, view.daily_flux.plant_count);
}

fn cloneMassBalance(
    allocator: std.mem.Allocator,
    bytes: *std.Io.Writer.Allocating,
    state: mass_balance.State,
    expected_shape: mass_balance.ExpectedShape,
) !mass_balance.State {
    bytes.clearRetainingCapacity();
    try mass_balance.write(&bytes.writer, state);
    var reader = std.Io.Reader.fixed(bytes.written());
    return mass_balance.read(allocator, &reader, expected_shape);
}

test "mass balance rollback snapshot deeply owns accumulated cell and layer closure" {
    const accumulated = @import("../validation/accumulated_cell_conservation.zig");
    const hourly = @import("../validation/hourly_cell_conservation.zig");
    const inventory = @import("../validation/landscape_mass_inventory.zig");
    const layer_local = @import("../validation/layer_local_conservation.zig");
    var live: mass_balance.State = .{ .boundary_ledger = .{}, .monitor = null };
    defer live.deinit();
    const before = [_]inventory.Storage{.{ .water_m3 = 1 }};
    const after = [_]inventory.Storage{.{ .water_m3 = 2 }};
    const activity = [_]hourly.BoundaryActivity{.{ .water_input_m3 = 1 }};
    var report = try accumulated.evaluateAndCommit(
        &live.accumulated_cell_closure,
        std.testing.allocator,
        std.testing.allocator,
        &before,
        &after,
        &activity,
        &.{1},
        .{ .absolute_per_area = .{}, .relative = 1.0e-9 },
        0,
    );
    defer report.deinit(std.testing.allocator);
    try live.hourly_cell_closure.recordAccepted(report);
    const layout = try layer_local.Layout.init(1, 1, 1);
    var layer_state = try layer_local.AccumulatedState.initEmpty(
        std.testing.allocator,
        layout,
    );
    @memset(layer_state.baseline_storage, .{});
    @memset(layer_state.latest_storage, .{});
    @memset(layer_state.cumulative_activity, .{});
    const soil_scope = try layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
    layer_state.baseline_storage[soil_scope].water_m3 = 3;
    layer_state.latest_storage[soil_scope].water_m3 = 4;
    layer_state.cumulative_activity[soil_scope].water_input_m3 = 1;
    layer_state.accepted_hour_count = 1;
    live.accumulated_layer_closure = layer_state;
    try live.hourly_layer_closure.recordAccepted(report);
    try live.boundary_ledger.accumulateAccepted(.{ .mineral_fertilizer_carbon_g_c = 108 });

    var codec: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer codec.deinit();
    var snapshot = try cloneMassBalance(
        std.testing.allocator,
        &codec,
        live,
        .{ .cell_count = 1, .soil_layer_capacity = 1, .snow_layer_capacity = 1 },
    );
    defer snapshot.deinit();
    try live.boundary_ledger.accumulateAccepted(.{ .mineral_fertilizer_carbon_g_c = 54 });
    try std.testing.expectEqual(@as(f64, 108), snapshot.boundary_ledger.cumulative.mineral_fertilizer_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 162), live.boundary_ledger.cumulative.mineral_fertilizer_carbon_g_c);
    live.accumulated_cell_closure.?.latest_storage[0].water_m3 = 99;
    live.accumulated_cell_closure.?.cumulative_activity[0].water_input_m3 = 98;
    live.accumulated_layer_closure.?.latest_storage[soil_scope].water_m3 = 97;
    live.accumulated_layer_closure.?.cumulative_activity[soil_scope].water_input_m3 = 96;
    try std.testing.expectEqual(
        @as(f64, 2),
        snapshot.accumulated_cell_closure.?.latest_storage[0].water_m3,
    );
    try std.testing.expectEqual(
        @as(f64, 1),
        snapshot.accumulated_cell_closure.?.cumulative_activity[0].water_input_m3,
    );
    try std.testing.expect(
        snapshot.accumulated_cell_closure.?.latest_storage.ptr !=
            live.accumulated_cell_closure.?.latest_storage.ptr,
    );
    try std.testing.expectEqual(
        @as(f64, 4),
        snapshot.accumulated_layer_closure.?.latest_storage[soil_scope].water_m3,
    );
    try std.testing.expectEqual(
        @as(f64, 1),
        snapshot.accumulated_layer_closure.?.cumulative_activity[soil_scope].water_input_m3,
    );
    try std.testing.expect(
        snapshot.accumulated_layer_closure.?.latest_storage.ptr !=
            live.accumulated_layer_closure.?.latest_storage.ptr,
    );
}

test "stable journal restores exact transient bytes after late failure" {
    const Ledger = struct { accepted: []f64, attempts: usize, finite: bool };
    var values = [_]f64{ 0.0, -0.0, @bitCast(@as(u64, 0x7ff8000000000042)) };
    var ledger: Ledger = .{ .accepted = &values, .attempts = 3, .finite = false };
    var journal: StableJournal = .{ .allocator = std.testing.allocator };
    defer journal.deinit();
    // The visitor itself is tested with a minimal fake target graph elsewhere;
    // direct segments isolate exact-byte restoration, including NaN payloads.
    try journal.appendBytes(std.mem.sliceAsBytes(ledger.accepted));
    try journal.appendBytes(std.mem.asBytes(&ledger.attempts));
    try journal.appendBytes(std.mem.asBytes(&ledger.finite));
    @memset(values[0..], 9.0);
    ledger.attempts = 99;
    ledger.finite = true;
    journal.restore();
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(values[0])));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(values[1])));
    try std.testing.expectEqual(@as(u64, 0x7ff8000000000042), @as(u64, @bitCast(values[2])));
    try std.testing.expectEqual(@as(usize, 3), ledger.attempts);
    try std.testing.expect(!ledger.finite);
}

test "stable journal reverse order restores overlapping segments exactly" {
    var bytes = [_]u8{ 0, 1, 2, 3, 4, 5 };
    var journal: StableJournal = .{ .allocator = std.testing.allocator };
    defer journal.deinit();
    try journal.appendBytes(&bytes);
    @memset(bytes[2..5], 0xaa);
    try journal.appendBytes(bytes[2..5]);
    @memset(bytes[0..], 0xff);

    journal.restore();
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5 }, &bytes);
}

test "stable journal restores optional tag transitions exactly" {
    var resolved_year: ?u16 = null;
    var prior_timestamp: ?struct { year: i32, day: u16 } = .{ .year = 2001, .day = 365 };
    var journal: StableJournal = .{ .allocator = std.testing.allocator };
    defer journal.deinit();
    try journal.appendBytes(std.mem.asBytes(&resolved_year));
    try journal.appendBytes(std.mem.asBytes(&prior_timestamp));

    resolved_year = 2002;
    prior_timestamp = null;
    journal.restore();

    try std.testing.expectEqual(@as(?u16, null), resolved_year);
    try std.testing.expectEqual(@as(i32, 2001), prior_timestamp.?.year);
    try std.testing.expectEqual(@as(u16, 365), prior_timestamp.?.day);
}

test "nested stable layout snapshots current stage entry bytes" {
    var value: u64 = 11;
    var outer: StableJournal = .{ .allocator = std.testing.allocator };
    defer outer.deinit();
    try outer.appendBytes(std.mem.asBytes(&value));

    // Earlier accepted science inside the external hour precedes this stage.
    value = 22;
    var nested: StableJournal = .{ .allocator = std.testing.allocator };
    defer nested.deinit();
    try nested.captureCurrentLayoutFrom(&outer);

    value = 33;
    nested.restore();
    try std.testing.expectEqual(@as(u64, 22), value);
    outer.restore();
    try std.testing.expectEqual(@as(u64, 11), value);
}

const SyntheticOwner = struct {
    allocator: std.mem.Allocator,
    topology: []usize,
    values: []f64,

    fn init(allocator: std.mem.Allocator, topology: []const usize) !@This() {
        const owned_topology = try allocator.dupe(usize, topology);
        errdefer allocator.free(owned_topology);
        const values = try allocator.alloc(f64, topology.len);
        for (values, 0..) |*value, index| value.* = @floatFromInt(index + 1);
        return .{ .allocator = allocator, .topology = owned_topology, .values = values };
    }
    fn clone(self: *const @This()) !@This() {
        const result = try init(self.allocator, self.topology);
        @memcpy(result.values, self.values);
        return result;
    }
    fn cloneInto(self: *const @This(), allocator: std.mem.Allocator) !@This() {
        const result = try init(allocator, self.topology);
        @memcpy(result.values, self.values);
        return result;
    }
    fn deinit(self: *@This()) void {
        self.allocator.free(self.values);
        self.allocator.free(self.topology);
        self.* = undefined;
    }
};

const SyntheticLedgers = struct {
    management_inputs: u64,
    canopy_diagnostic: f64,
    soil_acceptance: f64,
};

fn syntheticAttempt(owner: *SyntheticOwner, ledgers: *SyntheticLedgers, materialized_weather_input: f64) !void {
    var owner_swap = OwnerSwap(SyntheticOwner).begin(owner, try owner.clone());
    defer owner_swap.deinit();
    var stable: StableJournal = .{ .allocator = owner.allocator };
    defer stable.deinit();
    try stable.appendBytes(std.mem.asBytes(ledgers));
    var accepted = false;
    defer if (!accepted) stable.restore();

    ledgers.management_inputs += 1;
    ledgers.canopy_diagnostic += materialized_weather_input;
    var replacement = try SyntheticOwner.init(owner.allocator, &.{ 4, 3, 2, 1 });
    var previous = owner.*;
    owner.* = replacement;
    previous.deinit();
    replacement = undefined;
    try Transaction.injectFailureForTest(.after_canopy_and_management);

    owner.values[0] += 8;
    ledgers.soil_acceptance += 7.25;
    try Transaction.injectFailureForTest(.after_soil_solve);

    owner_swap.commit();
    accepted = true;
}

test "owner swap rolls topology reallocation back without aliasing" {
    var live = try SyntheticOwner.init(std.testing.allocator, &.{ 1, 2, 3 });
    defer live.deinit();
    var guard = OwnerSwap(SyntheticOwner).begin(&live, try live.clone());
    defer guard.deinit();
    var replacement = try SyntheticOwner.init(std.testing.allocator, &.{ 9, 8, 7, 6, 5 });
    var previous = live;
    live = replacement;
    previous.deinit();
    replacement = undefined;
    guard.rollback();
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3 }, live.topology);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3 }, live.values);
}

test "reusable owner workspace keeps rollback-promoted generations alive and allocation-free" {
    var counter: CountingAllocator = .{ .child = std.testing.allocator };
    var workspace = OwnerWorkspace(SyntheticOwner).init(counter.allocator());
    defer workspace.deinit();
    var live = try SyntheticOwner.init(std.testing.allocator, &.{ 1, 2, 3 });
    defer live.deinit();

    // First rollback promotes arena 0 into live ownership.
    {
        var guard = try workspace.begin(&live, SyntheticOwner.cloneInto);
        defer guard.deinit();
        var replacement = try SyntheticOwner.init(std.testing.allocator, &.{ 9, 8, 7, 6 });
        var previous = live;
        live = replacement;
        previous.deinit();
        replacement = undefined;
        guard.rollback();
    }
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3 }, live.topology);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3 }, live.values);

    // Second rollback promotes arena 1 and releases arena 0 only after its
    // former live owners have moved into and been deinitialized from backup.
    live.values[1] = 42;
    {
        var guard = try workspace.begin(&live, SyntheticOwner.cloneInto);
        defer guard.deinit();
        live.values[0] = -7;
        guard.rollback();
    }
    try std.testing.expectEqualSlices(f64, &.{ 1, 42, 3 }, live.values);

    // Both same-shaped arena generations are warm. Accepted transactions use
    // the non-live arena repeatedly without any backing allocation.
    counter.resetCounters();
    for (0..4) |_| {
        var guard = try workspace.begin(&live, SyntheticOwner.cloneInto);
        guard.commit();
        guard.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), counter.allocation_calls);
    try std.testing.expectEqual(@as(usize, 0), counter.requested_bytes);
    try std.testing.expectEqualSlices(f64, &.{ 1, 42, 3 }, live.values);
}

test "reusable owner workspace survives success rollback generation cycles with topology changes" {
    var counter: CountingAllocator = .{ .child = std.testing.allocator };
    var workspace = OwnerWorkspace(SyntheticOwner).init(counter.allocator());
    defer workspace.deinit();
    var live = try SyntheticOwner.init(std.testing.allocator, &.{ 1, 2, 3 });
    defer live.deinit();

    // Success warms arena A without changing live ownership.
    {
        var guard = try workspace.begin(&live, SyntheticOwner.cloneInto);
        live.values[2] = 30;
        guard.commit();
        guard.deinit();
    }
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 30 }, live.values);

    // Rollback promotes A after a failed topology growth.
    {
        var guard = try workspace.begin(&live, SyntheticOwner.cloneInto);
        defer guard.deinit();
        var replacement = try SyntheticOwner.init(std.testing.allocator, &.{ 9, 8, 7, 6, 5 });
        var previous = live;
        live = replacement;
        previous.deinit();
        replacement = undefined;
        guard.rollback();
    }
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3 }, live.topology);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 30 }, live.values);

    // The next successful hour resets/uses B while A remains live.
    {
        var guard = try workspace.begin(&live, SyntheticOwner.cloneInto);
        try std.testing.expectEqualSlices(f64, &.{ 1, 2, 30 }, live.values);
        live.values[1] = 22;
        guard.commit();
        guard.deinit();
    }
    try std.testing.expectEqualSlices(f64, &.{ 1, 22, 30 }, live.values);

    // Both generations are warm. Rollback now promotes B after a topology
    // shrink, releasing A only after its former owners are deinitialized.
    counter.resetCounters();
    {
        var guard = try workspace.begin(&live, SyntheticOwner.cloneInto);
        defer guard.deinit();
        var replacement = try SyntheticOwner.init(std.testing.allocator, &.{ 4, 4 });
        var previous = live;
        live = replacement;
        previous.deinit();
        replacement = undefined;
        guard.rollback();
    }
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3 }, live.topology);
    try std.testing.expectEqualSlices(f64, &.{ 1, 22, 30 }, live.values);

    // Final success resets/uses A again; reading live B before and after the
    // reset detects the generation UAF that a single retained arena caused.
    {
        var guard = try workspace.begin(&live, SyntheticOwner.cloneInto);
        try std.testing.expectEqualSlices(f64, &.{ 1, 22, 30 }, live.values);
        guard.commit();
        guard.deinit();
    }
    try std.testing.expectEqualSlices(f64, &.{ 1, 22, 30 }, live.values);
    try std.testing.expectEqual(@as(usize, 0), counter.allocation_calls);
    try std.testing.expectEqual(@as(usize, 0), counter.requested_bytes);
}

test "canopy topology rollback excludes nested harvest carbon aliases" {
    const CanopyState = @import("../canopy/photosynthesis/photosynthesis.zig").State;
    const CarbonState = @import("../canopy/photosynthesis/carbon_exchange.zig").State;
    const HarvestContext = struct { carbon_exchange_state: *CarbonState };
    const HourlyContext = struct { plant_harvest: *HarvestContext };

    var live_canopy = try CanopyState.init(std.testing.allocator, 1, 1, &.{3}, &.{ 1, 1, 1 }, &.{ 1, 1, 1 });
    defer live_canopy.deinit();
    var canopy_guard = OwnerSwap(CanopyState).begin(&live_canopy, try live_canopy.clone());
    defer canopy_guard.deinit();
    var live_carbon = try CarbonState.init(std.testing.allocator, 3);
    defer live_carbon.deinit();
    live_carbon.fixed_carbon_g_c_per_h[0..3].* = .{ 4, 5, 6 };
    var carbon_guard = OwnerSwap(CarbonState).begin(&live_carbon, try live_carbon.clone(std.testing.allocator));
    defer carbon_guard.deinit();
    var harvest = HarvestContext{ .carbon_exchange_state = &live_carbon };
    const hourly = HourlyContext{ .plant_harvest = &harvest };

    // This is the production alias shape: the hourly harvest context points
    // through the owner payload rather than through its optional wrapper.
    const aliased = std.mem.sliceAsBytes(hourly.plant_harvest.carbon_exchange_state.fixed_carbon_g_c_per_h);
    var excluded_ranges: ExcludedRanges = .{ .allocator = std.testing.allocator };
    defer excluded_ranges.deinit();
    try collectReachableRanges(&excluded_ranges, live_carbon);
    excluded_ranges.finish();
    try std.testing.expect(excluded_ranges.overlaps(aliased));

    try live_canopy.compactPlantToInitialTopology(0);
    var replacement = try CarbonState.init(std.testing.allocator, live_canopy.branch_node_offsets.len - 1);
    var previous = live_carbon;
    live_carbon = replacement;
    previous.deinit();
    replacement = undefined;
    try std.testing.expectEqual(@as(usize, 1), live_carbon.branchCount());

    // Restore additional owners before the checkpoint canopy swap, matching
    // the production defer order. The testing allocator detects UAF/double-free.
    carbon_guard.rollback();
    canopy_guard.rollback();
    try std.testing.expectEqual(@as(usize, 3), live_carbon.branchCount());
    try std.testing.expectEqualSlices(f64, &.{ 4, 5, 6 }, live_carbon.fixed_carbon_g_c_per_h);
    try std.testing.expectEqual(@as(usize, 3), live_canopy.branch_node_offsets.len - 1);
}

test "late failures rollback management canopy soil and retry matches restart" {
    var live = try SyntheticOwner.init(std.testing.allocator, &.{ 1, 2, 3 });
    defer live.deinit();
    var ledgers: SyntheticLedgers = .{ .management_inputs = 0, .canopy_diagnostic = -0.0, .soil_acceptance = 0 };
    var external_weather_cursor: usize = 0;
    external_weather_cursor += 1;
    const materialized_weather_input: f64 = 2.5;

    inline for (.{ Transaction.FailurePoint.after_canopy_and_management, .after_soil_solve }) |point| {
        testing_failure_point = point;
        defer testing_failure_point = null;
        try std.testing.expectError(error.InjectedOuterHourFailure, syntheticAttempt(&live, &ledgers, materialized_weather_input));
        try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3 }, live.topology);
        try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3 }, live.values);
        try std.testing.expectEqual(@as(u64, 0), ledgers.management_inputs);
        try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(ledgers.canopy_diagnostic)));
        try std.testing.expectEqual(@as(f64, 0), ledgers.soil_acceptance);
        // The transaction starts after input materialization. Rollback never
        // pretends to rewind external I/O; retry reuses these same hour bytes.
        try std.testing.expectEqual(@as(usize, 1), external_weather_cursor);
        testing_failure_point = null;
    }

    // A failed attempt must not consume management inputs. Its retry equals a
    // clean continuous hour, and a clone/restart followed by the next hour is
    // identical to the uninterrupted path.
    var continuous = try live.clone();
    defer continuous.deinit();
    var continuous_ledgers = ledgers;
    try syntheticAttempt(&continuous, &continuous_ledgers, materialized_weather_input);
    try syntheticAttempt(&live, &ledgers, materialized_weather_input);
    try std.testing.expectEqualDeep(continuous.topology, live.topology);
    try std.testing.expectEqualDeep(continuous.values, live.values);
    try std.testing.expectEqualDeep(continuous_ledgers, ledgers);
    try std.testing.expectEqual(@as(u64, 1), ledgers.management_inputs);

    var restarted = try live.clone();
    defer restarted.deinit();
    var restarted_ledgers = ledgers;
    try syntheticAttempt(&live, &ledgers, materialized_weather_input);
    try syntheticAttempt(&restarted, &restarted_ledgers, materialized_weather_input);
    try std.testing.expectEqualDeep(live.topology, restarted.topology);
    try std.testing.expectEqualDeep(live.values, restarted.values);
    try std.testing.expectEqualDeep(ledgers, restarted_ledgers);
}

test "outer-hour soil gas owner restores resized descriptors and backing state" {
    const GasStep = @import("../soil/gas/transport_step.zig").State;
    var workspace = OwnerWorkspace(GasStep).init(std.testing.allocator);
    defer workspace.deinit();
    var live = try GasStep.init(std.testing.allocator, 1);
    defer live.deinit();
    live.atmospheric_flux_g_per_h[0] = 3.25;

    var guard = try workspace.begin(&live, GasStep.clone);
    live.accepted_face_flux_g_per_h = try live.allocator.realloc(
        live.accepted_face_flux_g_per_h,
        @import("../soil/gas/transport.zig").species_count,
    );
    live.accepted_faces = try live.allocator.realloc(live.accepted_faces, 1);
    @memset(live.accepted_face_flux_g_per_h, 6);
    live.atmospheric_flux_g_per_h[0] = -8;
    guard.rollback();
    guard.deinit();

    try std.testing.expectEqual(@as(usize, 0), live.accepted_face_flux_g_per_h.len);
    try std.testing.expectEqual(@as(usize, 0), live.accepted_faces.len);
    try std.testing.expectEqual(@as(f64, 3.25), live.atmospheric_flux_g_per_h[0]);
}

test "late outer failure restores plant water cumulative and dry diagnostic before retry" {
    const dry_branch = @import("../surface/litter_chemistry_carrier_rebase.zig");
    const saved_dry_branch_executions = dry_branch.dry_branch_executions;
    defer dry_branch.dry_branch_executions = saved_dry_branch_executions;
    dry_branch.dry_branch_executions = 41;

    var live = try PlantWaterStateUpdate.State.init(std.testing.allocator, 1, 1);
    defer live.deinit();
    var uninterrupted = try PlantWaterStateUpdate.State.init(std.testing.allocator, 1, 1);
    defer uninterrupted.deinit();
    live.cumulative_water_source_m3_by_plant[0] = 1.25;
    uninterrupted.cumulative_water_source_m3_by_plant[0] = 1.25;
    const inputs: PlantWaterStateUpdate.Inputs = .{
        .cell_area_m2 = &.{2},
        .internal_water_depth_m_per_m2_by_plant = &.{0.2},
        .living_surface_water_m3_by_plant = &.{0.1},
        .standing_dead_surface_water_m3_by_plant = &.{0.05},
        .transpiration_m3_per_h_by_plant = &.{-0.01},
        .living_evaporation_m3_per_h_by_plant = &.{-0.02},
        .standing_dead_evaporation_m3_per_h_by_plant = &.{-0.03},
    };
    try PlantWaterStateUpdate.refresh(&uninterrupted, inputs);

    var stable: StableJournal = .{ .allocator = std.testing.allocator };
    defer stable.deinit();
    inline for (@typeInfo(PlantWaterStateUpdate.State).@"struct".fields) |field| {
        if (field.type == []f64 and !std.mem.eql(u8, field.name, "cumulative_water_source_m3_by_plant"))
            try stable.appendBytes(std.mem.sliceAsBytes(@field(live, field.name)));
    }
    try stable.appendBytes(std.mem.asBytes(&dry_branch.dry_branch_executions));
    const checkpoint_cumulative = live.cumulative_water_source_m3_by_plant[0];

    try PlantWaterStateUpdate.refresh(&live, inputs);
    dry_branch.dry_branch_executions += 1;
    // Stable transients restore first; then the checkpoint bundle restores the
    // cumulative carrier before the exact same external-hour inputs are retried.
    stable.restore();
    live.cumulative_water_source_m3_by_plant[0] = checkpoint_cumulative;
    try std.testing.expectEqual(@as(u64, 41), dry_branch.dry_branch_executions);
    try std.testing.expectEqual(@as(f64, 1.25), live.cumulative_water_source_m3_by_plant[0]);

    try PlantWaterStateUpdate.refresh(&live, inputs);
    dry_branch.dry_branch_executions += 1;
    inline for (@typeInfo(PlantWaterStateUpdate.State).@"struct".fields) |field|
        if (field.type == []f64)
            try std.testing.expectEqualSlices(f64, @field(uninterrupted, field.name), @field(live, field.name));
    try std.testing.expectEqual(@as(u64, 42), dry_branch.dry_branch_executions);
}

test "later acceptance failure restores accepted tillage sidecar" {
    var sidecar = try TillageActivity.Sidecar.init(
        std.testing.allocator,
        1,
        2,
        .{ .relative = 64 * std.math.floatEps(f64) },
    );
    defer sidecar.deinit();

    var stable: StableJournal = .{ .allocator = std.testing.allocator };
    defer stable.deinit();
    try stable.appendBytes(std.mem.sliceAsBytes(sidecar.accepted_soil));
    try stable.appendBytes(std.mem.sliceAsBytes(sidecar.staged_soil));
    try stable.appendBytes(std.mem.sliceAsBytes(sidecar.accepted_surface));
    try stable.appendBytes(std.mem.sliceAsBytes(sidecar.staged_surface));
    try stable.appendBytes(std.mem.sliceAsBytes(sidecar.staged_cell));
    try stable.appendBytes(std.mem.asBytes(&sidecar.attempt_active));

    // Tillage accepts and publishes, then a later layer-acceptance gate fails.
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
        &.{ .{ .water_m3 = 10 }, .{ .water_m3 = 2 } },
        .{ .water_m3 = 3 },
        .{ .water_m3 = 2 },
        &.{ .{ .water_m3 = 9 }, .{ .water_m3 = 5 } },
        .{ .water_m3 = 1 },
    );
    try sidecar.commitAttempt();
    try std.testing.expect((try sidecar.soilRecord(0, 0, 1)).active);

    stable.restore();
    try std.testing.expect(!sidecar.attempt_active);
    try std.testing.expectEqualDeep(TillageActivity.Record{}, try sidecar.soilRecord(0, 0, 1));
    try std.testing.expectEqualDeep(TillageActivity.Record{}, try sidecar.surfaceRecord(0, 0));
}

test "production outer hour explicitly owns soil gas and pending surface ledger" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/ecosys_ng.zig",
        std.testing.allocator,
        .limited(2 * 1024 * 1024),
    );
    defer std.testing.allocator.free(source);
    const accept_start = std.mem.indexOf(u8, source, "noinline fn acceptHourAndPublish(") orelse return error.MissingAcceptHourPhase;
    const prepare_start = std.mem.indexOfPos(u8, source, accept_start, "noinline fn prepareHourlyScience(") orelse return error.MissingPrepareHourlySciencePhase;
    const identity_start = std.mem.indexOfPos(u8, source, prepare_start, "noinline fn resolveHourIdentity(") orelse return error.MissingHourIdentityPhase;
    const plant_management_start = std.mem.indexOfPos(u8, source, identity_start, "noinline fn advancePlantLifecycleManagement(") orelse return error.MissingPlantLifecycleManagementPhase;
    const fertilizer_start = std.mem.indexOfPos(u8, source, plant_management_start, "noinline fn advanceFertilizerManagement(") orelse return error.MissingFertilizerManagementPhase;
    const disturbance_start = std.mem.indexOfPos(u8, source, fertilizer_start, "noinline fn advancePreScienceDisturbance(") orelse return error.MissingPreScienceDisturbancePhase;
    const climate_start = std.mem.indexOfPos(u8, source, disturbance_start, "noinline fn advanceDailyClimateAcclimation(") orelse return error.MissingDailyClimateAcclimationPhase;
    const atmosphere_start = std.mem.indexOfPos(u8, source, climate_start, "noinline fn prepareHourlyWeatherAndAtmosphere(") orelse return error.MissingHourlyWeatherAtmospherePhase;
    const advance_start = std.mem.indexOfPos(u8, source, prepare_start, "noinline fn advanceHour(") orelse return error.MissingAdvanceHourPhase;
    const timeline_start = std.mem.indexOfPos(u8, source, advance_start, "noinline fn runTimeline(") orelse return error.MissingTimelinePhase;
    const accept_phase = source[accept_start..prepare_start];
    const extracted_phases = source[identity_start..advance_start];
    const advance_phase = source[advance_start..timeline_start];
    try std.testing.expect(identity_start < plant_management_start);
    try std.testing.expect(plant_management_start < fertilizer_start);
    try std.testing.expect(fertilizer_start < disturbance_start);
    try std.testing.expect(disturbance_start < climate_start);
    try std.testing.expect(climate_start < atmosphere_start);
    try std.testing.expect(atmosphere_start < advance_start);
    try std.testing.expect(std.mem.indexOf(u8, extracted_phases, "driver_context.executor") == null);
    try std.testing.expect(std.mem.indexOf(u8, extracted_phases, "runOwned") == null);
    try std.testing.expectEqual(
        @as(usize, 4),
        std.mem.count(u8, source[identity_start..timeline_start], "const management_date = try ecosys.plant_management_dispatch.dateFromTimestamp(timestamp);"),
    );
    inline for (.{
        "driver_context.outer_hour_soil_gas_transport_workspace.*.begin(",
        "&driver_context.soil_gas_transport_state.*,\n        ecosys.soil_gas_transport_step.State.clone",
        ".cumulative_water_source_m3_by_plant = driver_context.plant_water_state_update_state.*.cumulative_water_source_m3_by_plant",
        ".plant_water_state_update = &driver_context.plant_water_state_update_state.*",
        ".pending_surface_gas_ledger = driver_context.pending_surface_gas_ledger.*",
        ".tillage_local_activity = &driver_context.tillage_local_activity.*",
        ".dry_branch_executions = dry_branch_executions_owner",
        // issue-076: item 2 embeds a `\n`, so on a CRLF checkout a plain
        // `std.mem.count` reported 0 for a binding that is present and correct.
    }) |binding| try std.testing.expectEqual(
        @as(usize, 1),
        source_scan.countIgnoringCarriageReturns(advance_phase, binding),
    );
    const weather_next = std.mem.indexOf(u8, advance_phase, "try stream.next()") orelse return error.MissingWeatherMaterialization;
    const transaction_begin = std.mem.indexOf(u8, advance_phase, "driver_context.outer_hour_transaction_workspace.*.begin(") orelse return error.MissingOuterHourTransaction;
    const outer_defer = std.mem.indexOfPos(u8, advance_phase, transaction_begin, "defer outer_hour_transaction.deinit();") orelse return error.MissingOuterHourDefer;
    const carbon_defer = std.mem.indexOfPos(u8, advance_phase, outer_defer, "defer outer_hour_carbon_exchange_transaction.deinit();") orelse return error.MissingCarbonExchangeDefer;
    const gas_defer = std.mem.indexOfPos(u8, advance_phase, carbon_defer, "defer outer_hour_soil_gas_transport_transaction.deinit();") orelse return error.MissingSoilGasDefer;
    const stable_capture = std.mem.indexOfPos(u8, advance_phase, transaction_begin, "captureStable(&driver_context.hourly_science_context.*") orelse return error.MissingStableOwnerCapture;
    const transient_capture = std.mem.indexOfPos(u8, advance_phase, stable_capture, "captureStable(&outer_hour_transients") orelse return error.MissingTransientCapture;
    const unbind_defer = std.mem.indexOfPos(u8, advance_phase, transient_capture, "defer driver_context.fixed_hour_recovery_workspace.*.unbindOuterTransaction(&outer_hour_transaction);") orelse return error.MissingFixedHourUnbindDefer;
    const accepted_storage_call = std.mem.indexOfPos(u8, advance_phase, unbind_defer, "try prepareAcceptedHourStorageAndLedgers(driver_context, advance_context);") orelse return error.MissingAcceptedHourStorageCall;
    const identity_call = std.mem.indexOfPos(u8, advance_phase, accepted_storage_call, "try resolveHourIdentity(driver_context, advance_context, timestamp)") orelse return error.MissingHourIdentityCall;
    const plant_management_call = std.mem.indexOfPos(u8, advance_phase, identity_call, "try advancePlantLifecycleManagement(driver_context, &hour_identity);") orelse return error.MissingPlantLifecycleManagementCall;
    const fertilizer_call = std.mem.indexOfPos(u8, advance_phase, plant_management_call, "try advanceFertilizerManagement(driver_context, advance_context, &hour_identity);") orelse return error.MissingFertilizerManagementCall;
    const disturbance_call = std.mem.indexOfPos(u8, advance_phase, fertilizer_call, "try advancePreScienceDisturbance(driver_context, advance_context, &hour_identity);") orelse return error.MissingPreScienceDisturbanceCall;
    const climate_call = std.mem.indexOfPos(u8, advance_phase, disturbance_call, "try advanceDailyClimateAcclimation(driver_context, timeline_state, advance_context, &hour_identity);") orelse return error.MissingDailyClimateAcclimationCall;
    const atmosphere_call = std.mem.indexOfPos(u8, advance_phase, climate_call, "try prepareHourlyWeatherAndAtmosphere(") orelse return error.MissingHourlyWeatherAtmosphereCall;
    const prepare_call = std.mem.indexOfPos(u8, advance_phase, atmosphere_call, "try prepareHourlyScience(driver_context, timeline_state, advance_context, &prepare_science_context);") orelse return error.MissingPrepareHourlyScienceCall;
    const gas_name_defer = std.mem.indexOfPos(u8, advance_phase, prepare_call, "defer driver_context.allocator.*.free(gas_failure_file_name);") orelse return error.MissingGasFailureNameDefer;
    const solute_name_defer = std.mem.indexOfPos(u8, advance_phase, gas_name_defer, "defer driver_context.allocator.*.free(solute_failure_file_name);") orelse return error.MissingSoluteFailureNameDefer;
    const failure_injection = std.mem.indexOfPos(u8, advance_phase, solute_name_defer, "try ecosys.outer_hour_transaction.Transaction.injectFailureForTest(.after_canopy_and_management);") orelse return error.MissingOuterHourFailureInjection;
    const execute_call = std.mem.indexOfPos(u8, advance_phase, failure_injection, "executeHourlyScience(") orelse return error.MissingExecuteHourlyScienceCall;
    // Failure snapshots are addressed by an explicitly bound directory handle
    // plus the owned file name, never by a path joined against the process
    // working directory. `output_tree.logs` sits outside the output
    // coordinator's transactional scientific categories, so a rejected hour's
    // diagnostics survive rollback, while the deck directory that can be the
    // output root's parent never receives diagnostic files. A cwd-relative
    // binding would silently reintroduce both hazards.
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, advance_phase, "std.Io.Dir.cwd()"));
    const gas_logs_directory = std.mem.indexOfPos(u8, advance_phase, execute_call, ".directory = driver_context.output_tree.*.logs,") orelse return error.MissingGasFailureLogsDirectory;
    const gas_file_binding = std.mem.indexOfPos(u8, advance_phase, gas_logs_directory, ".file_path = gas_failure_file_name,") orelse return error.MissingGasFailureFileBinding;
    const solute_logs_directory = std.mem.indexOfPos(u8, advance_phase, gas_file_binding, ".directory = driver_context.output_tree.*.logs,") orelse return error.MissingSoluteFailureLogsDirectory;
    const solute_file_binding = std.mem.indexOfPos(u8, advance_phase, solute_logs_directory, ".file_path = solute_failure_file_name,") orelse return error.MissingSoluteFailureFileBinding;
    const post_call = std.mem.indexOfPos(u8, advance_phase, solute_file_binding, "try postScienceAccounting(driver_context,") orelse return error.MissingPostScienceAccountingCall;
    const accept_call = std.mem.indexOfPos(u8, advance_phase, post_call, "try acceptHourAndPublish(driver_context,") orelse return error.MissingAcceptHourCall;
    const soil_gas_commit = std.mem.indexOf(u8, accept_phase, "outer_hour_soil_gas_transport_transaction.*.commit();") orelse return error.MissingSoilGasCommit;
    const carbon_commit = std.mem.indexOfPos(u8, accept_phase, soil_gas_commit, "outer_hour_carbon_exchange_transaction.*.commit();") orelse return error.MissingCarbonExchangeCommit;
    const scientific_commit = std.mem.indexOfPos(u8, accept_phase, carbon_commit, "outer_hour_transaction.*.commit();") orelse return error.MissingOuterHourCommit;
    try std.testing.expect(weather_next < transaction_begin);
    try std.testing.expect(transaction_begin < stable_capture);
    try std.testing.expect(transaction_begin < outer_defer);
    try std.testing.expect(outer_defer < carbon_defer);
    try std.testing.expect(carbon_defer < gas_defer);
    try std.testing.expect(stable_capture < transient_capture);
    try std.testing.expect(transient_capture < unbind_defer);
    try std.testing.expect(unbind_defer < accepted_storage_call);
    try std.testing.expect(accepted_storage_call < identity_call);
    try std.testing.expect(identity_call < plant_management_call);
    try std.testing.expect(plant_management_call < fertilizer_call);
    try std.testing.expect(fertilizer_call < disturbance_call);
    try std.testing.expect(disturbance_call < climate_call);
    try std.testing.expect(climate_call < atmosphere_call);
    try std.testing.expect(atmosphere_call < prepare_call);
    try std.testing.expect(prepare_call < gas_name_defer);
    try std.testing.expect(gas_name_defer < solute_name_defer);
    try std.testing.expect(solute_name_defer < failure_injection);
    try std.testing.expect(failure_injection < execute_call);
    try std.testing.expect(execute_call < gas_logs_directory);
    try std.testing.expect(gas_logs_directory < gas_file_binding);
    try std.testing.expect(gas_file_binding < solute_logs_directory);
    try std.testing.expect(solute_logs_directory < solute_file_binding);
    try std.testing.expect(solute_file_binding < post_call);
    try std.testing.expect(post_call < accept_call);
    try std.testing.expect(soil_gas_commit < scientific_commit);
    try std.testing.expect(soil_gas_commit < carbon_commit);
    try std.testing.expect(carbon_commit < scientific_commit);
}

const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocation_calls: usize = 0,
    requested_bytes: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocate,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn resetCounters(self: *@This()) void {
        self.allocation_calls = 0;
        self.requested_bytes = 0;
    }

    fn selfFromOpaque(pointer: *anyopaque) *@This() {
        return @ptrCast(@alignCast(pointer));
    }

    fn allocate(pointer: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self = selfFromOpaque(pointer);
        const result = self.child.rawAlloc(len, alignment, return_address) orelse return null;
        self.allocation_calls += 1;
        self.requested_bytes += len;
        return result;
    }

    fn resize(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self = selfFromOpaque(pointer);
        if (!self.child.rawResize(memory, alignment, new_len, return_address)) return false;
        if (new_len > memory.len) self.requested_bytes += new_len - memory.len;
        return true;
    }

    fn remap(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self = selfFromOpaque(pointer);
        const result = self.child.rawRemap(memory, alignment, new_len, return_address) orelse return null;
        if (new_len > memory.len) self.requested_bytes += new_len - memory.len;
        return result;
    }

    fn free(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        selfFromOpaque(pointer).child.rawFree(memory, alignment, return_address);
    }
};

/// Nine checkpoint-shaped owner groups for a moderate production grid. Each
/// group is fragmented like real state owners and paired with a serialization
/// buffer. This intentionally benchmarks transaction memory mechanics rather
/// than model science or any example deck.
fn exerciseCheckpointShapedAllocation(owner_allocator: std.mem.Allocator, codec_allocator: std.mem.Allocator) !void {
    const section_bytes = [_]usize{
        512 * 1024, // grid and plants
        768 * 1024, // plant development
        2 * 1024 * 1024, // roots
        2 * 1024 * 1024, // canopy
        3 * 1024 * 1024, // biogeochemistry
        2 * 1024 * 1024, // organic matter
        4 * 1024 * 1024, // solute/gas/snow transport
        3 * 1024 * 1024, // geometry and hydrology
        512 * 1024, // plant accounting
    };
    const fragments_per_section = 8;
    var owners: [section_bytes.len * fragments_per_section][]u8 = undefined;
    var owner_count: usize = 0;
    errdefer while (owner_count > 0) {
        owner_count -= 1;
        owner_allocator.free(owners[owner_count]);
    };
    for (section_bytes, 0..) |section_len, section_index| {
        const fragment_len = section_len / fragments_per_section;
        for (0..fragments_per_section) |_| {
            owners[owner_count] = try owner_allocator.alloc(u8, fragment_len);
            @memset(owners[owner_count], @as(u8, @intCast(section_index + 1)));
            owner_count += 1;
        }
        const codec = try codec_allocator.alloc(u8, section_len);
        @memset(codec, @as(u8, @intCast(0xa0 + section_index)));
        codec_allocator.free(codec);
    }
    while (owner_count > 0) {
        owner_count -= 1;
        owner_allocator.free(owners[owner_count]);
    }
}

test "retained transaction arenas eliminate steady-state checkpoint-shaped backing allocations" {
    const measured_hours = 4;

    var baseline_counter: CountingAllocator = .{ .child = std.testing.allocator };
    const baseline_start = std.Io.Clock.Timestamp.now(std.testing.io, .cpu_process);
    for (0..measured_hours) |_| try exerciseCheckpointShapedAllocation(
        baseline_counter.allocator(),
        baseline_counter.allocator(),
    );
    const baseline_end = std.Io.Clock.Timestamp.now(std.testing.io, .cpu_process);

    var retained_counter: CountingAllocator = .{ .child = std.testing.allocator };
    var snapshot_arena = std.heap.ArenaAllocator.init(retained_counter.allocator());
    defer snapshot_arena.deinit();
    var codec_arena = std.heap.ArenaAllocator.init(retained_counter.allocator());
    defer codec_arena.deinit();
    // Arena reset may consolidate the first high-water mark. Two warm-ups make
    // the measured interval represent long-running hourly steady state.
    for (0..2) |_| {
        _ = snapshot_arena.reset(.retain_capacity);
        _ = codec_arena.reset(.retain_capacity);
        try exerciseCheckpointShapedAllocation(snapshot_arena.allocator(), codec_arena.allocator());
    }
    _ = snapshot_arena.reset(.retain_capacity);
    _ = codec_arena.reset(.retain_capacity);
    retained_counter.resetCounters();
    const retained_start = std.Io.Clock.Timestamp.now(std.testing.io, .cpu_process);
    for (0..measured_hours) |_| {
        _ = snapshot_arena.reset(.retain_capacity);
        _ = codec_arena.reset(.retain_capacity);
        try exerciseCheckpointShapedAllocation(snapshot_arena.allocator(), codec_arena.allocator());
    }
    const retained_end = std.Io.Clock.Timestamp.now(std.testing.io, .cpu_process);

    const baseline_ns = baseline_start.durationTo(baseline_end).raw.nanoseconds;
    const retained_ns = retained_start.durationTo(retained_end).raw.nanoseconds;
    std.debug.print(
        "outer-hour allocation benchmark: baseline_ns={d} baseline_bytes={d} baseline_allocations={d} retained_ns={d} retained_bytes={d} retained_allocations={d}\n",
        .{ baseline_ns, baseline_counter.requested_bytes, baseline_counter.allocation_calls, retained_ns, retained_counter.requested_bytes, retained_counter.allocation_calls },
    );
    try std.testing.expectEqual(@as(usize, 0), retained_counter.allocation_calls);
    try std.testing.expectEqual(@as(usize, 0), retained_counter.requested_bytes);
    try std.testing.expect(snapshot_arena.queryCapacity() > 0);
    try std.testing.expect(codec_arena.queryCapacity() > 0);
}

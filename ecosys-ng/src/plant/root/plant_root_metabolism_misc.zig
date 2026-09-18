//! `plant_root_metabolism` declarations: misc.
//!
//! Split out of `plant_root_metabolism.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const RootState = @import("plant_root_system.zig").State;
const NutrientResult = @import("plant_root_nutrient_uptake.zig").Result;
const root_domain_count = @import("plant_root_system.zig").biological_domain_count;
const group_axis_sink = @import("plant_root_metabolism_axis_sink.zig");
const group_state_update = @import("plant_root_metabolism_state_update.zig");
const group_growth = @import("plant_root_metabolism_growth.zig");
const group_litter = @import("plant_root_metabolism_litter.zig");

pub const AxisWorkspace = struct {
    allocator: std.mem.Allocator,
    axis_capacity: usize,
    sink_strengths: []group_axis_sink.RootAxisSinkStrength,
    primary_sink_fractions: []f64,
    secondary_sink_fractions: []f64,
    primary_metabolism: []group_growth.SecondaryRootResult,
    secondary_metabolism: []group_growth.SecondaryRootResult,
    primary_senescence: []group_litter.SecondaryRootSenescence,
    secondary_senescence: []group_litter.SecondaryRootSenescence,
    candidate_primary_deficit_absorption: []group_state_update.SecondaryRootDeficitAbsorption,
    candidate_primary_deficit_active: []bool,
    primary_deficit_absorption: []group_state_update.SecondaryRootDeficitAbsorption,
    primary_deficit_active: []bool,
    primary_active: []bool,
    secondary_active: []bool,
    primary_processed_by_domain: []bool,
    secondary_processed_by_domain: []bool,
    withdrawal_sink_fractions: []f64,
    withdrawal_layer_thickness_m: []f64,
    withdrawal_layer_bottom_m: []f64,
    withdrawn_layers: []usize,
    withdrawn_fractions: []f64,
    primary_respiration_allocation_fractions: []f64,
    primary_respiration_root_layer_indices: []usize,
    primary_length_m_by_layer: []f64,
    pre_update_primary_depth_m: []f64,
    primary_respiration_actual_delta_by_layer: []f64,
    primary_respiration_oxygen_unlimited_delta_by_layer: []f64,
    primary_respiration_carbon_unlimited_delta_by_layer: []f64,

    pub fn init(allocator: std.mem.Allocator, axis_capacity: usize, soil_layer_count: usize) !AxisWorkspace {
        if (axis_capacity == 0 or soil_layer_count == 0) return error.InvalidRootMetabolismWorkspaceDimensions;
        const strengths = try allocator.alloc(group_axis_sink.RootAxisSinkStrength, axis_capacity);
        errdefer allocator.free(strengths);
        const primary_fractions = try allocator.alloc(f64, axis_capacity);
        errdefer allocator.free(primary_fractions);
        const secondary_fractions = try allocator.alloc(f64, axis_capacity);
        errdefer allocator.free(secondary_fractions);
        const primary_metabolism = try allocator.alloc(group_growth.SecondaryRootResult, axis_capacity);
        errdefer allocator.free(primary_metabolism);
        const secondary_metabolism = try allocator.alloc(group_growth.SecondaryRootResult, axis_capacity);
        errdefer allocator.free(secondary_metabolism);
        const primary_senescence = try allocator.alloc(group_litter.SecondaryRootSenescence, axis_capacity);
        errdefer allocator.free(primary_senescence);
        const secondary_senescence = try allocator.alloc(group_litter.SecondaryRootSenescence, axis_capacity);
        errdefer allocator.free(secondary_senescence);
        const candidate_deficit_absorption = try allocator.alloc(group_state_update.SecondaryRootDeficitAbsorption, axis_capacity);
        errdefer allocator.free(candidate_deficit_absorption);
        const candidate_deficit_active = try allocator.alloc(bool, axis_capacity);
        errdefer allocator.free(candidate_deficit_active);
        const deficit_absorption = try allocator.alloc(group_state_update.SecondaryRootDeficitAbsorption, axis_capacity);
        errdefer allocator.free(deficit_absorption);
        const deficit_active = try allocator.alloc(bool, axis_capacity);
        errdefer allocator.free(deficit_active);
        const primary_active = try allocator.alloc(bool, axis_capacity);
        errdefer allocator.free(primary_active);
        const secondary_active = try allocator.alloc(bool, axis_capacity);
        errdefer allocator.free(secondary_active);
        const primary_processed = try allocator.alloc(bool, try std.math.mul(usize, axis_capacity, root_domain_count));
        errdefer allocator.free(primary_processed);
        const secondary_processed = try allocator.alloc(bool, try std.math.mul(usize, axis_capacity, root_domain_count));
        errdefer allocator.free(secondary_processed);
        const withdrawal_fractions = try allocator.alloc(f64, try std.math.mul(usize, axis_capacity, soil_layer_count));
        errdefer allocator.free(withdrawal_fractions);
        const withdrawal_thickness = try allocator.alloc(f64, soil_layer_count);
        errdefer allocator.free(withdrawal_thickness);
        const withdrawal_bottom = try allocator.alloc(f64, soil_layer_count);
        errdefer allocator.free(withdrawal_bottom);
        const withdrawn_layers = try allocator.alloc(usize, soil_layer_count);
        errdefer allocator.free(withdrawn_layers);
        const withdrawn_fractions = try allocator.alloc(f64, soil_layer_count);
        errdefer allocator.free(withdrawn_fractions);
        const respiration_fractions = try allocator.alloc(f64, soil_layer_count);
        errdefer allocator.free(respiration_fractions);
        const respiration_indices = try allocator.alloc(usize, soil_layer_count);
        errdefer allocator.free(respiration_indices);
        const primary_lengths = try allocator.alloc(f64, soil_layer_count);
        errdefer allocator.free(primary_lengths);
        const pre_update_primary_depth = try allocator.alloc(f64, axis_capacity);
        errdefer allocator.free(pre_update_primary_depth);
        const respiration_actual_delta = try allocator.alloc(f64, soil_layer_count);
        errdefer allocator.free(respiration_actual_delta);
        const respiration_oxygen_unlimited_delta = try allocator.alloc(f64, soil_layer_count);
        errdefer allocator.free(respiration_oxygen_unlimited_delta);
        const respiration_carbon_unlimited_delta = try allocator.alloc(f64, soil_layer_count);
        @memset(strengths, .{ .primary_m = 0, .secondary_m = 0 });
        @memset(primary_fractions, 0);
        @memset(secondary_fractions, 0);
        @memset(primary_metabolism, std.mem.zeroes(group_growth.SecondaryRootResult));
        @memset(secondary_metabolism, std.mem.zeroes(group_growth.SecondaryRootResult));
        @memset(primary_senescence, std.mem.zeroes(group_litter.SecondaryRootSenescence));
        @memset(secondary_senescence, std.mem.zeroes(group_litter.SecondaryRootSenescence));
        @memset(candidate_deficit_absorption, std.mem.zeroes(group_state_update.SecondaryRootDeficitAbsorption));
        @memset(candidate_deficit_active, false);
        @memset(deficit_absorption, std.mem.zeroes(group_state_update.SecondaryRootDeficitAbsorption));
        @memset(deficit_active, false);
        @memset(primary_active, false);
        @memset(secondary_active, false);
        @memset(primary_processed, false);
        @memset(secondary_processed, false);
        @memset(withdrawal_fractions, 0);
        @memset(withdrawal_thickness, 0);
        @memset(withdrawal_bottom, 0);
        @memset(withdrawn_layers, 0);
        @memset(withdrawn_fractions, 0);
        @memset(respiration_fractions, 0);
        @memset(respiration_indices, 0);
        @memset(primary_lengths, 0);
        @memset(pre_update_primary_depth, 0);
        @memset(respiration_actual_delta, 0);
        @memset(respiration_oxygen_unlimited_delta, 0);
        @memset(respiration_carbon_unlimited_delta, 0);
        return .{
            .allocator = allocator,
            .axis_capacity = axis_capacity,
            .sink_strengths = strengths,
            .primary_sink_fractions = primary_fractions,
            .secondary_sink_fractions = secondary_fractions,
            .primary_metabolism = primary_metabolism,
            .secondary_metabolism = secondary_metabolism,
            .primary_senescence = primary_senescence,
            .secondary_senescence = secondary_senescence,
            .candidate_primary_deficit_absorption = candidate_deficit_absorption,
            .candidate_primary_deficit_active = candidate_deficit_active,
            .primary_deficit_absorption = deficit_absorption,
            .primary_deficit_active = deficit_active,
            .primary_active = primary_active,
            .secondary_active = secondary_active,
            .primary_processed_by_domain = primary_processed,
            .secondary_processed_by_domain = secondary_processed,
            .withdrawal_sink_fractions = withdrawal_fractions,
            .withdrawal_layer_thickness_m = withdrawal_thickness,
            .withdrawal_layer_bottom_m = withdrawal_bottom,
            .withdrawn_layers = withdrawn_layers,
            .withdrawn_fractions = withdrawn_fractions,
            .primary_respiration_allocation_fractions = respiration_fractions,
            .primary_respiration_root_layer_indices = respiration_indices,
            .primary_length_m_by_layer = primary_lengths,
            .pre_update_primary_depth_m = pre_update_primary_depth,
            .primary_respiration_actual_delta_by_layer = respiration_actual_delta,
            .primary_respiration_oxygen_unlimited_delta_by_layer = respiration_oxygen_unlimited_delta,
            .primary_respiration_carbon_unlimited_delta_by_layer = respiration_carbon_unlimited_delta,
        };
    }

    pub fn deinit(self: *AxisWorkspace) void {
        self.allocator.free(self.primary_respiration_carbon_unlimited_delta_by_layer);
        self.allocator.free(self.primary_respiration_oxygen_unlimited_delta_by_layer);
        self.allocator.free(self.primary_respiration_actual_delta_by_layer);
        self.allocator.free(self.pre_update_primary_depth_m);
        self.allocator.free(self.primary_length_m_by_layer);
        self.allocator.free(self.primary_respiration_root_layer_indices);
        self.allocator.free(self.primary_respiration_allocation_fractions);
        self.allocator.free(self.secondary_processed_by_domain);
        self.allocator.free(self.primary_processed_by_domain);
        self.allocator.free(self.withdrawn_fractions);
        self.allocator.free(self.withdrawn_layers);
        self.allocator.free(self.withdrawal_layer_bottom_m);
        self.allocator.free(self.withdrawal_layer_thickness_m);
        self.allocator.free(self.withdrawal_sink_fractions);
        self.allocator.free(self.secondary_active);
        self.allocator.free(self.primary_active);
        self.allocator.free(self.primary_deficit_active);
        self.allocator.free(self.primary_deficit_absorption);
        self.allocator.free(self.candidate_primary_deficit_active);
        self.allocator.free(self.candidate_primary_deficit_absorption);
        self.allocator.free(self.secondary_senescence);
        self.allocator.free(self.primary_senescence);
        self.allocator.free(self.secondary_metabolism);
        self.allocator.free(self.primary_metabolism);
        self.allocator.free(self.secondary_sink_fractions);
        self.allocator.free(self.primary_sink_fractions);
        self.allocator.free(self.sink_strengths);
        self.* = undefined;
    }

    pub fn resetAxes(self: *AxisWorkspace, active_axis_count: usize) !void {
        if (active_axis_count > self.axis_capacity) return error.RootMetabolismWorkspaceCapacityExceeded;
        @memset(self.sink_strengths[0..active_axis_count], .{ .primary_m = 0, .secondary_m = 0 });
        @memset(self.primary_sink_fractions[0..active_axis_count], 0);
        @memset(self.secondary_sink_fractions[0..active_axis_count], 0);
        @memset(self.primary_metabolism[0..active_axis_count], std.mem.zeroes(group_growth.SecondaryRootResult));
        @memset(self.secondary_metabolism[0..active_axis_count], std.mem.zeroes(group_growth.SecondaryRootResult));
        @memset(self.primary_senescence[0..active_axis_count], std.mem.zeroes(group_litter.SecondaryRootSenescence));
        @memset(self.secondary_senescence[0..active_axis_count], std.mem.zeroes(group_litter.SecondaryRootSenescence));
        @memset(self.candidate_primary_deficit_absorption[0..active_axis_count], std.mem.zeroes(group_state_update.SecondaryRootDeficitAbsorption));
        @memset(self.candidate_primary_deficit_active[0..active_axis_count], false);
        @memset(self.primary_deficit_absorption[0..active_axis_count], std.mem.zeroes(group_state_update.SecondaryRootDeficitAbsorption));
        @memset(self.primary_deficit_active[0..active_axis_count], false);
        @memset(self.primary_active[0..active_axis_count], false);
        @memset(self.secondary_active[0..active_axis_count], false);
        @memset(self.pre_update_primary_depth_m[0..active_axis_count], 0);
    }

    pub fn beginPlantHour(self: *AxisWorkspace, active_axis_count: usize) !void {
        if (active_axis_count > self.axis_capacity) return error.RootMetabolismWorkspaceCapacityExceeded;
        @memset(self.primary_processed_by_domain[0 .. active_axis_count * root_domain_count], false);
        @memset(self.secondary_processed_by_domain[0 .. active_axis_count * root_domain_count], false);
        @memset(self.withdrawal_sink_fractions, 0);
    }

    pub fn withdrawalSinkIndex(self: AxisWorkspace, layer: usize, axis: usize) !usize {
        if (axis >= self.axis_capacity or
            layer >= self.withdrawal_layer_thickness_m.len)
            return error.RootMetabolismWorkspaceCapacityExceeded;
        return layer * self.axis_capacity + axis;
    }

    pub fn primaryWasProcessed(self: AxisWorkspace, domain: usize, axis: usize) !bool {
        if (domain >= root_domain_count or axis >= self.axis_capacity) return error.RootMetabolismWorkspaceCapacityExceeded;
        return self.primary_processed_by_domain[axis * root_domain_count + domain];
    }

    pub fn markPrimaryProcessed(self: *AxisWorkspace, domain: usize, axis: usize) !void {
        if (domain >= root_domain_count or axis >= self.axis_capacity) return error.RootMetabolismWorkspaceCapacityExceeded;
        self.primary_processed_by_domain[axis * root_domain_count + domain] = true;
    }

    pub fn secondaryWasProcessed(self: AxisWorkspace, domain: usize, axis: usize) !bool {
        if (domain >= root_domain_count or axis >= self.axis_capacity) return error.RootMetabolismWorkspaceCapacityExceeded;
        return self.secondary_processed_by_domain[axis * root_domain_count + domain];
    }

    pub fn markSecondaryProcessed(self: *AxisWorkspace, domain: usize, axis: usize) !void {
        if (domain >= root_domain_count or axis >= self.axis_capacity) return error.RootMetabolismWorkspaceCapacityExceeded;
        self.secondary_processed_by_domain[axis * root_domain_count + domain] = true;
    }
};

pub const GridWorkspace = struct {
    allocator: std.mem.Allocator,
    per_cell: []AxisWorkspace,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, axis_capacity: usize, soil_layer_count: usize) !GridWorkspace {
        if (cell_count == 0) return error.InvalidRootMetabolismWorkspaceDimensions;
        const cells = try allocator.alloc(AxisWorkspace, cell_count);
        errdefer allocator.free(cells);
        var initialized: usize = 0;
        errdefer for (cells[0..initialized]) |*cell| cell.deinit();
        for (cells) |*cell| {
            cell.* = try AxisWorkspace.init(allocator, axis_capacity, soil_layer_count);
            initialized += 1;
        }
        return .{ .allocator = allocator, .per_cell = cells };
    }

    pub fn deinit(self: *GridWorkspace) void {
        for (self.per_cell) |*cell| cell.deinit();
        self.allocator.free(self.per_cell);
        self.* = undefined;
    }
};

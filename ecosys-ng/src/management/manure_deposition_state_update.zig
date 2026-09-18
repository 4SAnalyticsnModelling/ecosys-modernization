const std = @import("std");
const canopy = @import("../canopy/photosynthesis/photosynthesis.zig");
const grazing_manure = @import("grazing_manure.zig");

pub const fraction_count = grazing_manure.biochemical_fraction_count;

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    plant_species_per_cell: usize,
    organic_carbon_g_c_per_h_by_cell_fraction: []f64,
    organic_nitrogen_g_n_per_h_by_cell_fraction: []f64,
    organic_phosphorus_g_p_per_h_by_cell_fraction: []f64,
    inorganic_nitrogen_g_n_per_h_by_cell: []f64,
    inorganic_phosphorus_g_p_per_h_by_cell: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        cell_count: usize,
        plant_species_per_cell: usize,
    ) !State {
        if (cell_count == 0 or plant_species_per_cell == 0)
            return error.InvalidManureStateUpdateDimensions;
        const fraction_values = try std.math.mul(usize, cell_count, fraction_count);
        const organic_value_count = try std.math.mul(usize, fraction_values, 3);
        const inorganic_value_count = try std.math.mul(usize, cell_count, 2);
        const organic = try allocator.alloc(f64, organic_value_count);
        errdefer allocator.free(organic);
        const inorganic = try allocator.alloc(f64, inorganic_value_count);
        errdefer allocator.free(inorganic);
        @memset(organic, 0);
        @memset(inorganic, 0);
        return .{
            .allocator = allocator,
            .cell_count = cell_count,
            .plant_species_per_cell = plant_species_per_cell,
            .organic_carbon_g_c_per_h_by_cell_fraction = organic[0..fraction_values],
            .organic_nitrogen_g_n_per_h_by_cell_fraction = organic[fraction_values .. 2 * fraction_values],
            .organic_phosphorus_g_p_per_h_by_cell_fraction = organic[2 * fraction_values ..],
            .inorganic_nitrogen_g_n_per_h_by_cell = inorganic[0..cell_count],
            .inorganic_phosphorus_g_p_per_h_by_cell = inorganic[cell_count..],
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(
            self.organic_carbon_g_c_per_h_by_cell_fraction.ptr[0 .. 3 * self.cell_count * fraction_count],
        );
        self.allocator.free(
            self.inorganic_nitrogen_g_n_per_h_by_cell.ptr[0 .. 2 * self.cell_count],
        );
        self.* = undefined;
    }
};

/// Exact EXTRACT lines 109–127. The removed sub-hour full-model cycle makes
/// the accepted hourly products equivalent to the legacy `NFZ == 1` gate.
pub fn refresh(
    state: *State,
    products_by_plant: []const grazing_manure.Products,
) !void {
    const plant_count = try std.math.mul(
        usize,
        state.cell_count,
        state.plant_species_per_cell,
    );
    if (products_by_plant.len != plant_count)
        return error.InvalidManureStateUpdateDimensions;

    for (0..state.cell_count) |cell|
        _ = try totalsForCell(state, products_by_plant, cell);

    for (0..state.cell_count) |cell| {
        const totals =
            totalsForCell(state, products_by_plant, cell) catch unreachable;
        const first = cell * fraction_count;
        for (0..fraction_count) |fraction| {
            state.organic_carbon_g_c_per_h_by_cell_fraction[first + fraction] =
                totals.organic[fraction].carbon_g;
            state.organic_nitrogen_g_n_per_h_by_cell_fraction[first + fraction] =
                totals.organic[fraction].nitrogen_g;
            state.organic_phosphorus_g_p_per_h_by_cell_fraction[first + fraction] =
                totals.organic[fraction].phosphorus_g;
        }
        state.inorganic_nitrogen_g_n_per_h_by_cell[cell] = totals.inorganic_n;
        state.inorganic_phosphorus_g_p_per_h_by_cell[cell] = totals.inorganic_p;
    }
}

const Totals = struct {
    organic: [fraction_count]canopy.ElementalMass,
    inorganic_n: f64,
    inorganic_p: f64,
};

fn totalsForCell(
    state: *const State,
    products_by_plant: []const grazing_manure.Products,
    cell: usize,
) !Totals {
    var totals: Totals = .{
        .organic = [_]canopy.ElementalMass{.{}} ** fraction_count,
        .inorganic_n = 0,
        .inorganic_p = 0,
    };
    const first_plant = cell * state.plant_species_per_cell;
    for (first_plant..first_plant + state.plant_species_per_cell) |plant| {
        const products = products_by_plant[plant];
        for (0..fraction_count) |fraction| {
            const source = products.organic_by_biochemical_fraction[fraction];
            inline for (@typeInfo(@TypeOf(source)).@"struct".fields) |field| {
                const value = @field(source, field.name);
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidManureStateUpdateInput;
                const next = @field(totals.organic[fraction], field.name) + value;
                if (!std.math.isFinite(next))
                    return error.NonFiniteManureStateUpdate;
                @field(totals.organic[fraction], field.name) = next;
            }
        }
        inline for (.{
            products.inorganic_nitrogen_g_n,
            products.inorganic_phosphorus_g_p,
        }) |value| if (!std.math.isFinite(value) or value < 0)
            return error.InvalidManureStateUpdateInput;
        totals.inorganic_n += products.inorganic_nitrogen_g_n;
        totals.inorganic_p += products.inorganic_phosphorus_g_p;
        if (!std.math.isFinite(totals.inorganic_n) or
            !std.math.isFinite(totals.inorganic_p))
            return error.NonFiniteManureStateUpdate;
    }
    return totals;
}

test "EXTRACT manure state_update preserves plant and fraction axes" {
    var state = try State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    var products = [_]grazing_manure.Products{ .{}, .{} };
    products[0].organic_by_biochemical_fraction[0] =
        .{ .carbon_g = 1, .nitrogen_g = 2, .phosphorus_g = 3 };
    products[1].organic_by_biochemical_fraction[0] =
        .{ .carbon_g = 10, .nitrogen_g = 20, .phosphorus_g = 30 };
    products[0].organic_by_biochemical_fraction[3].carbon_g = 4;
    products[1].organic_by_biochemical_fraction[3].carbon_g = 40;
    products[0].inorganic_nitrogen_g_n = 5;
    products[1].inorganic_nitrogen_g_n = 50;
    products[0].inorganic_phosphorus_g_p = 6;
    products[1].inorganic_phosphorus_g_p = 60;
    try refresh(&state, &products);
    try std.testing.expectEqual(@as(f64, 11), state.organic_carbon_g_c_per_h_by_cell_fraction[0]);
    try std.testing.expectEqual(@as(f64, 22), state.organic_nitrogen_g_n_per_h_by_cell_fraction[0]);
    try std.testing.expectEqual(@as(f64, 33), state.organic_phosphorus_g_p_per_h_by_cell_fraction[0]);
    try std.testing.expectEqual(@as(f64, 44), state.organic_carbon_g_c_per_h_by_cell_fraction[3]);
    try std.testing.expectEqual(@as(f64, 55), state.inorganic_nitrogen_g_n_per_h_by_cell[0]);
    try std.testing.expectEqual(@as(f64, 66), state.inorganic_phosphorus_g_p_per_h_by_cell[0]);
}

test "late invalid manure preserves all state_update arrays" {
    var state = try State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    inline for (@typeInfo(State).@"struct".fields) |field|
        if (field.type == []f64) @memset(@field(state, field.name), 7);
    var products = [_]grazing_manure.Products{ .{}, .{} };
    products[1].inorganic_phosphorus_g_p = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidManureStateUpdateInput,
        refresh(&state, &products),
    );
    inline for (@typeInfo(State).@"struct".fields) |field|
        if (field.type == []f64)
            for (@field(state, field.name)) |value|
                try std.testing.expectEqual(@as(f64, 7), value);
}

const std = @import("std");
const solute = @import("../soil/solute/transport.zig");
const gas = @import("../soil/gas/transport.zig");
const snow = @import("../soil/solute/snow_solute_transport.zig");
const surface = @import("../soil/solute/surface_solute_routing.zig");

/// Runtime extensive-flux ledger replacing the distributed `X*`/`T*` COMMON
/// accumulators consumed by REDIST. Values are added only after a nonlinear
/// kernel converges; rejected iterates never enter persistent accounting.
pub const Ledger = struct {
    allocator: std.mem.Allocator,
    solute_net_mol: []f64,
    gaseous_net_g: []f64,
    dissolved_gas_net_g: []f64,
    macropore_dissolved_gas_net_g: []f64,
    band_dissolved_gas_net_g: []f64,
    snow_net_g: []f64,
    surface_net_mol: []f64,
    exported_solute_mol: []f64,
    exported_gas_g: []f64,
    exported_snow_g: []f64,
    exported_surface_mol: []f64,

    pub fn init(allocator: std.mem.Allocator, solute_components: usize, gas_components: usize, snow_components: usize, surface_components: usize, solute_species: usize, gas_species: usize, snow_species: usize, surface_species: usize) !Ledger {
        if (gas_species != gas.species_count or snow_species != snow.species_count) return error.RedistributionScientificSpeciesMismatch;
        const solute_net = try allocateZero(allocator, solute_components);
        errdefer allocator.free(solute_net);
        const gaseous_net = try allocateZero(allocator, gas_components);
        errdefer allocator.free(gaseous_net);
        const dissolved_net = try allocateZero(allocator, gas_components);
        errdefer allocator.free(dissolved_net);
        const macropore_dissolved_net = try allocateZero(allocator, gas_components);
        errdefer allocator.free(macropore_dissolved_net);
        const band_net = try allocateZero(allocator, gas_components);
        errdefer allocator.free(band_net);
        const snow_net = try allocateZero(allocator, snow_components);
        errdefer allocator.free(snow_net);
        const surface_net = try allocateZero(allocator, surface_components);
        errdefer allocator.free(surface_net);
        const exported_solute = try allocateZero(allocator, solute_species);
        errdefer allocator.free(exported_solute);
        const exported_gas = try allocateZero(allocator, gas_species);
        errdefer allocator.free(exported_gas);
        const exported_snow = try allocateZero(allocator, snow_species);
        errdefer allocator.free(exported_snow);
        const exported_surface = try allocateZero(allocator, surface_species);
        errdefer allocator.free(exported_surface);
        return .{ .allocator = allocator, .solute_net_mol = solute_net, .gaseous_net_g = gaseous_net, .dissolved_gas_net_g = dissolved_net, .macropore_dissolved_gas_net_g = macropore_dissolved_net, .band_dissolved_gas_net_g = band_net, .snow_net_g = snow_net, .surface_net_mol = surface_net, .exported_solute_mol = exported_solute, .exported_gas_g = exported_gas, .exported_snow_g = exported_snow, .exported_surface_mol = exported_surface };
    }

    pub fn deinit(self: *Ledger) void {
        self.allocator.free(self.exported_surface_mol);
        self.allocator.free(self.exported_snow_g);
        self.allocator.free(self.exported_gas_g);
        self.allocator.free(self.exported_solute_mol);
        self.allocator.free(self.surface_net_mol);
        self.allocator.free(self.snow_net_g);
        self.allocator.free(self.band_dissolved_gas_net_g);
        self.allocator.free(self.macropore_dissolved_gas_net_g);
        self.allocator.free(self.dissolved_gas_net_g);
        self.allocator.free(self.gaseous_net_g);
        self.allocator.free(self.solute_net_mol);
        self.* = undefined;
    }

    pub fn reset(self: *Ledger) void {
        inline for (@typeInfo(Ledger).@"struct".fields) |field| {
            if (field.type == []f64) @memset(@field(self, field.name), 0);
        }
    }

    pub fn accumulate(destination: []f64, changes: []const f64) !void {
        if (destination.len != changes.len) return error.RedistributionSizeMismatch;
        for (destination, changes) |*total, change| {
            if (!std.math.isFinite(change) or !std.math.isFinite(total.* + change)) return error.NonFiniteRedistributionFlux;
            total.* += change;
        }
    }
};

/// Validates every candidate first, then state_updates all transport domains and
/// resets the ledger. Failure leaves both model states and the ledger intact.
pub fn state_updateAndReset(ledger: *Ledger, solute_state: *solute.State, gas_state: *gas.State, snow_state: *snow.State, surface_state: *surface.State) !void {
    if (ledger.solute_net_mol.len != solute_state.amount_mol.len or ledger.gaseous_net_g.len != gas_state.gaseous_mass_g.len or ledger.dissolved_gas_net_g.len != gas_state.dissolved_mass_g.len or ledger.macropore_dissolved_gas_net_g.len != gas_state.macropore_dissolved_mass_g.len or ledger.band_dissolved_gas_net_g.len != gas_state.band_dissolved_mass_g.len or ledger.snow_net_g.len != snow_state.amount_g.len or ledger.surface_net_mol.len != surface_state.amount_mol.len or ledger.exported_solute_mol.len != solute_state.species_count or ledger.exported_gas_g.len != gas.species_count or ledger.exported_snow_g.len != snow.species_count or ledger.exported_surface_mol.len != surface_state.species_count) return error.RedistributionSizeMismatch;
    try validateCandidate(solute_state.amount_mol, ledger.solute_net_mol);
    try validateCandidate(gas_state.gaseous_mass_g, ledger.gaseous_net_g);
    try validateCandidate(gas_state.dissolved_mass_g, ledger.dissolved_gas_net_g);
    try validateCandidate(gas_state.macropore_dissolved_mass_g, ledger.macropore_dissolved_gas_net_g);
    try validateCandidate(gas_state.band_dissolved_mass_g, ledger.band_dissolved_gas_net_g);
    try validateCandidate(snow_state.amount_g, ledger.snow_net_g);
    try validateCandidate(surface_state.amount_mol, ledger.surface_net_mol);
    try validateExports(ledger.exported_solute_mol);
    try validateExports(ledger.exported_gas_g);
    try validateExports(ledger.exported_snow_g);
    try validateExports(ledger.exported_surface_mol);
    apply(solute_state.amount_mol, ledger.solute_net_mol);
    apply(gas_state.gaseous_mass_g, ledger.gaseous_net_g);
    apply(gas_state.dissolved_mass_g, ledger.dissolved_gas_net_g);
    apply(gas_state.macropore_dissolved_mass_g, ledger.macropore_dissolved_gas_net_g);
    apply(gas_state.band_dissolved_mass_g, ledger.band_dissolved_gas_net_g);
    apply(snow_state.amount_g, ledger.snow_net_g);
    apply(surface_state.amount_mol, ledger.surface_net_mol);
    ledger.reset();
}

fn allocateZero(allocator: std.mem.Allocator, count: usize) ![]f64 {
    const values = try allocator.alloc(f64, count);
    @memset(values, 0);
    return values;
}

fn validateCandidate(amounts: []const f64, changes: []const f64) !void {
    for (amounts, changes) |amount, change| {
        const candidate = amount + change;
        if (!std.math.isFinite(amount) or amount < 0 or !std.math.isFinite(change) or !std.math.isFinite(candidate) or candidate < 0) return error.InvalidRedistributionCandidate;
    }
}

fn validateExports(exports: []const f64) !void {
    for (exports) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRedistributionExport;
}

fn apply(amounts: []f64, changes: []const f64) void {
    for (amounts, changes) |*amount, change| amount.* += change;
}

test "REDIST transaction state_updates every runtime domain then clears fluxes" {
    var solute_state = try solute.State.init(std.testing.allocator, 1, 2);
    defer solute_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    var snow_state = try snow.State.init(std.testing.allocator, 1, 1);
    defer snow_state.deinit();
    var surface_state = try surface.State.init(std.testing.allocator, 1, 1, 3);
    defer surface_state.deinit();
    @memset(solute_state.amount_mol, 2);
    @memset(gas_state.gaseous_mass_g, 2);
    @memset(gas_state.dissolved_mass_g, 2);
    @memset(gas_state.band_dissolved_mass_g, 2);
    @memset(snow_state.amount_g, 2);
    @memset(surface_state.amount_mol, 2);
    var ledger = try Ledger.init(std.testing.allocator, solute_state.amount_mol.len, gas_state.gaseous_mass_g.len, snow_state.amount_g.len, surface_state.amount_mol.len, solute_state.species_count, gas.species_count, snow.species_count, surface_state.species_count);
    defer ledger.deinit();
    @memset(ledger.solute_net_mol, -0.5);
    @memset(ledger.gaseous_net_g, 0.5);
    @memset(ledger.dissolved_gas_net_g, -0.25);
    @memset(ledger.band_dissolved_gas_net_g, 0.25);
    @memset(ledger.snow_net_g, -0.5);
    @memset(ledger.surface_net_mol, 0.5);
    try state_updateAndReset(&ledger, &solute_state, &gas_state, &snow_state, &surface_state);
    try std.testing.expectEqual(@as(f64, 1.5), solute_state.amount_mol[0]);
    try std.testing.expectEqual(@as(f64, 2.5), gas_state.gaseous_mass_g[0]);
    try std.testing.expectEqual(@as(f64, 1.5), snow_state.amount_g[0]);
    for (ledger.solute_net_mol) |value| try std.testing.expectEqual(@as(f64, 0), value);
}

test "failed REDIST transaction changes no state and retains diagnostics" {
    var solute_state = try solute.State.init(std.testing.allocator, 1, 1);
    defer solute_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    var snow_state = try snow.State.init(std.testing.allocator, 1, 1);
    defer snow_state.deinit();
    var surface_state = try surface.State.init(std.testing.allocator, 1, 1, 1);
    defer surface_state.deinit();
    solute_state.amount_mol[0] = 1;
    gas_state.gaseous_mass_g[0] = 1;
    snow_state.amount_g[0] = 1;
    surface_state.amount_mol[0] = 1;
    var ledger = try Ledger.init(std.testing.allocator, 1, gas_state.gaseous_mass_g.len, snow_state.amount_g.len, 1, 1, gas.species_count, snow.species_count, 1);
    defer ledger.deinit();
    ledger.solute_net_mol[0] = -2;
    ledger.gaseous_net_g[0] = 1;
    try std.testing.expectError(error.InvalidRedistributionCandidate, state_updateAndReset(&ledger, &solute_state, &gas_state, &snow_state, &surface_state));
    try std.testing.expectEqual(@as(f64, 1), solute_state.amount_mol[0]);
    try std.testing.expectEqual(@as(f64, 1), gas_state.gaseous_mass_g[0]);
    try std.testing.expectEqual(@as(f64, -2), ledger.solute_net_mol[0]);
}

test "REDIST rejects sub-legacy-tolerance overdraw without clipping or reset" {
    var solute_state = try solute.State.init(std.testing.allocator, 1, 1);
    defer solute_state.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 1);
    defer gas_state.deinit();
    var snow_state = try snow.State.init(std.testing.allocator, 1, 1);
    defer snow_state.deinit();
    var surface_state = try surface.State.init(std.testing.allocator, 1, 1, 1);
    defer surface_state.deinit();
    solute_state.amount_mol[0] = 1;
    var ledger = try Ledger.init(std.testing.allocator, 1, gas_state.gaseous_mass_g.len, snow_state.amount_g.len, 1, 1, gas.species_count, snow.species_count, 1);
    defer ledger.deinit();
    ledger.solute_net_mol[0] = -1.0000000000001;

    try std.testing.expectError(error.InvalidRedistributionCandidate, state_updateAndReset(&ledger, &solute_state, &gas_state, &snow_state, &surface_state));
    try std.testing.expectEqual(@as(f64, 1), solute_state.amount_mol[0]);
    try std.testing.expectEqual(@as(f64, -1.0000000000001), ledger.solute_net_mol[0]);
}

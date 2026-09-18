const std = @import("std");

pub const OrganicMatter = struct { doc_g_c: f64, acetate_g_c: f64, don_g_n: f64, dop_g_p: f64 };

pub const State = struct { dissolved: OrganicMatter, adsorbed: OrganicMatter };

pub const Inputs = struct {
    water_volume_m3: f64,
    soil_mass_megagrams: f64,
    anion_exchange_capacity_mol_per_megagram: f64,
    adsorption_coefficient: f64,
    substrate_complex_fraction: f64,
    doc_fraction_of_dissolved_carbon: f64,
    acetate_fraction_of_dissolved_carbon: f64,
    sorption_rate_per_h: f64,
    timestep_h: f64,
    negligible_water_volume_m3: f64,
    negligible_carbon_g_c: f64,
    negligible_nitrogen_g_n: f64,
    negligible_phosphorus_g_p: f64,
};

pub const Flux = struct { doc_g_c: f64, acetate_g_c: f64, don_g_n: f64, dop_g_p: f64 };

/// Positive flux adsorbs and negative flux desorbs, matching NITRO CSORP,
/// CSORPA, ZSORP, and PSORP sign conventions.
pub fn calculate(state: State, inputs: Inputs) !Flux {
    try validateState(state);
    try validateInputs(inputs);
    if (inputs.water_volume_m3 <= inputs.negligible_water_volume_m3 or inputs.substrate_complex_fraction == 0) return .{ .doc_g_c = 0, .acetate_g_c = 0, .don_g_n = 0, .dop_g_p = 0 };
    const adsorption_capacity = inputs.soil_mass_megagrams * inputs.anion_exchange_capacity_mol_per_megagram * inputs.adsorption_coefficient * inputs.substrate_complex_fraction;
    const aqueous_capacity = inputs.water_volume_m3 * inputs.substrate_complex_fraction;
    if (adsorption_capacity + aqueous_capacity <= 0) return error.ZeroOrganicSorptionCapacity;
    const dissolved = floorMatter(state.dissolved, inputs);
    const adsorbed = floorMatter(state.adsorbed, inputs);
    return .{
        .doc_g_c = exchange(dissolved.doc_g_c, adsorbed.doc_g_c, adsorption_capacity, aqueous_capacity, inputs.doc_fraction_of_dissolved_carbon, inputs),
        .acetate_g_c = exchange(dissolved.acetate_g_c, adsorbed.acetate_g_c, adsorption_capacity, aqueous_capacity, inputs.acetate_fraction_of_dissolved_carbon, inputs),
        .don_g_n = exchange(dissolved.don_g_n, adsorbed.don_g_n, adsorption_capacity, aqueous_capacity, 0, inputs),
        .dop_g_p = exchange(dissolved.dop_g_p, adsorbed.dop_g_p, adsorption_capacity, aqueous_capacity, 0, inputs),
    };
}

pub fn state_update(state: *State, flux: Flux) !void {
    try validateState(state.*);
    inline for (@typeInfo(Flux).@"struct".fields) |field| if (!std.math.isFinite(@field(flux, field.name))) return error.NonFiniteOrganicSorptionFlux;
    var next = state.*;
    inline for (@typeInfo(Flux).@"struct".fields) |field| {
        const amount = @field(flux, field.name);
        @field(next.dissolved, field.name) -= amount;
        @field(next.adsorbed, field.name) += amount;
    }
    try validateState(next);
    state.* = next;
}

fn exchange(dissolved_amount: f64, adsorbed_amount: f64, adsorption_capacity: f64, aqueous_capacity: f64, carbon_fraction: f64, inputs: Inputs) f64 {
    var solid_capacity = adsorption_capacity;
    var water_capacity = aqueous_capacity;
    if (carbon_fraction > 0) {
        solid_capacity *= carbon_fraction;
        water_capacity *= carbon_fraction;
    }
    return inputs.sorption_rate_per_h * (dissolved_amount * solid_capacity - adsorbed_amount * water_capacity) / (solid_capacity + water_capacity) * inputs.timestep_h;
}

fn floorMatter(value: OrganicMatter, inputs: Inputs) OrganicMatter {
    return .{
        .doc_g_c = @max(inputs.negligible_carbon_g_c, value.doc_g_c),
        .acetate_g_c = @max(inputs.negligible_carbon_g_c, value.acetate_g_c),
        .don_g_n = @max(inputs.negligible_nitrogen_g_n, value.don_g_n),
        .dop_g_p = @max(inputs.negligible_phosphorus_g_p, value.dop_g_p),
    };
}

fn validateState(state: State) !void {
    inline for (.{ state.dissolved, state.adsorbed }) |matter| inline for (@typeInfo(OrganicMatter).@"struct".fields) |field| if (!std.math.isFinite(@field(matter, field.name)) or @field(matter, field.name) < -1e-14) return error.InvalidOrganicSorptionState;
}

fn validateInputs(inputs: Inputs) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name)) or @field(inputs, field.name) < 0) return error.InvalidOrganicSorptionInput;
    if (inputs.doc_fraction_of_dissolved_carbon > 1 or inputs.acetate_fraction_of_dissolved_carbon > 1 or inputs.timestep_h <= 0) return error.InvalidOrganicSorptionInput;
}

fn testInputs() Inputs {
    return .{ .water_volume_m3 = 2, .soil_mass_megagrams = 1, .anion_exchange_capacity_mol_per_megagram = 100, .adsorption_coefficient = 0.1, .substrate_complex_fraction = 0.5, .doc_fraction_of_dissolved_carbon = 0.7, .acetate_fraction_of_dissolved_carbon = 0.3, .sorption_rate_per_h = 0.2, .timestep_h = 1, .negligible_water_volume_m3 = 1e-12, .negligible_carbon_g_c = 1e-12, .negligible_nitrogen_g_n = 1e-12, .negligible_phosphorus_g_p = 1e-12 };
}

test "organic sorption transaction conserves every dissolved and adsorbed pool" {
    var state: State = .{ .dissolved = .{ .doc_g_c = 10, .acetate_g_c = 2, .don_g_n = 1, .dop_g_p = 0.2 }, .adsorbed = .{ .doc_g_c = 1, .acetate_g_c = 0.5, .don_g_n = 0.1, .dop_g_p = 0.02 } };
    const before = state;
    const flux = try calculate(state, testInputs());
    try state_update(&state, flux);
    inline for (@typeInfo(OrganicMatter).@"struct".fields) |field| try std.testing.expectApproxEqAbs(@field(before.dissolved, field.name) + @field(before.adsorbed, field.name), @field(state.dissolved, field.name) + @field(state.adsorbed, field.name), 1e-14);
    try std.testing.expect(flux.doc_g_c > 0);
}

test "organic desorption uses negative flux sign" {
    const state: State = .{ .dissolved = .{ .doc_g_c = 0.1, .acetate_g_c = 0.1, .don_g_n = 0.1, .dop_g_p = 0.1 }, .adsorbed = .{ .doc_g_c = 10, .acetate_g_c = 10, .don_g_n = 10, .dop_g_p = 10 } };
    const flux = try calculate(state, testInputs());
    try std.testing.expect(flux.doc_g_c < 0);
    try std.testing.expect(flux.don_g_n < 0);
}

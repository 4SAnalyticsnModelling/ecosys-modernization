// **A8a DISPOSITION: superseded by the bound UPTAKE hourly flux reset.**
//
// SpeciesTotals tiles uptake.f:342--358, RootFluxes tiles uptake.f:362--385, SaltFluxes
// tiles the ISALTG arm uptake.f:386--395. The root and salt layers are owned by
// plant_root_system.resetHourlyFluxes (src/plant/root/plant_root_system.zig:642), bound
// at src/ecosys_ng.zig:3619, which additionally snapshots sixteen uptake and demand
// arrays into previous_* at :643--658 before zeroing so the converged solver can
// compare iterations -- behaviour this candidate lacks. The species-total layer is
// reconstructed on demand from canopy energy aggregation, the water state_update, and
// per-plant sums over the root arrays, so it has no stored accumulator to reset.
// Do not bind this module.
// uptake reset group of docs/traceability/plant_reset_unbound_family_disposition.md
const std = @import("std");

pub const SaltMode = enum {
    disabled,
    dynamic,
};

pub const Dimensions = struct {
    species_count: usize,
    soil_layer_count: usize,
    root_axis_count_by_species: []const usize,

    pub fn rootUnitCount(self: Dimensions) !usize {
        if (self.species_count == 0 or
            self.soil_layer_count == 0 or
            self.root_axis_count_by_species.len != self.species_count)
            return error.InvalidPlantUptakeFluxDimensions;
        var axis_count: usize = 0;
        for (self.root_axis_count_by_species) |count| {
            if (count == 0) return error.InvalidPlantUptakeFluxDimensions;
            axis_count = std.math.add(usize, axis_count, count) catch
                return error.InvalidPlantUptakeFluxDimensions;
        }
        return std.math.mul(usize, axis_count, self.soil_layer_count) catch
            return error.InvalidPlantUptakeFluxDimensions;
    }
};

pub const SpeciesTotals = struct {
    radiative_flux_megajoules_per_step: []f64,
    latent_heat_flux_megajoules_per_step: []f64,
    sensible_heat_flux_megajoules_per_step: []f64,
    canopy_heat_flux_megajoules_per_step: []f64,
    water_vapor_flux_m3_per_step: []f64,
    thermal_radiation_megajoules_per_step: []f64,
    transpiration_m3_per_step: []f64,
    evaporation_m3_per_step: []f64,
    organic_carbon_uptake_g_c_per_step: []f64,
    organic_nitrogen_uptake_g_n_per_step: []f64,
    organic_phosphorus_uptake_g_p_per_step: []f64,
    ammonium_uptake_g_n_per_step: []f64,
    nitrate_uptake_g_n_per_step: []f64,
    dihydrogen_phosphate_uptake_g_p_per_step: []f64,
    hydrogen_phosphate_uptake_g_p_per_step: []f64,
    dinitrogen_fixation_g_n_per_step: []f64,
};

pub const RootFluxes = struct {
    water_uptake_m3_per_step: []f64,
    root_carbon_dioxide_production_g_c_per_step: []f64,
    oxygen_uptake_from_root_g_o_per_step: []f64,
    soil_carbon_dioxide_exchange_g_c_per_step: []f64,
    soil_oxygen_uptake_g_o_per_step: []f64,
    soil_methane_uptake_g_c_per_step: []f64,
    soil_dinitrogen_uptake_g_n_per_step: []f64,
    soil_ammonium_uptake_g_n_per_step: []f64,
    band_ammonium_uptake_g_n_per_step: []f64,
    soil_hydrogen_uptake_g_h_per_step: []f64,
    atmosphere_carbon_dioxide_flux_g_c_per_step: []f64,
    atmosphere_oxygen_flux_g_o_per_step: []f64,
    atmosphere_methane_flux_g_c_per_step: []f64,
    atmosphere_dinitrogen_flux_g_n_per_step: []f64,
    atmosphere_ammonia_flux_g_n_per_step: []f64,
    atmosphere_hydrogen_flux_g_h_per_step: []f64,
    internal_carbon_dioxide_flux_g_c_per_step: []f64,
    internal_oxygen_flux_g_o_per_step: []f64,
    internal_methane_flux_g_c_per_step: []f64,
    internal_dinitrogen_flux_g_n_per_step: []f64,
    internal_ammonia_flux_g_n_per_step: []f64,
    internal_hydrogen_flux_g_h_per_step: []f64,
};

pub const SaltFluxes = struct {
    aluminum_uptake_mol_per_step: []f64,
    iron_uptake_mol_per_step: []f64,
    calcium_uptake_mol_per_step: []f64,
    magnesium_uptake_mol_per_step: []f64,
    sodium_uptake_mol_per_step: []f64,
    potassium_uptake_mol_per_step: []f64,
    sulfate_uptake_mol_per_step: []f64,
    chloride_uptake_mol_per_step: []f64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    species_count: usize,
    root_unit_count: usize,
    species: SpeciesTotals,
    root: RootFluxes,
    salts: SaltFluxes,

    pub fn init(allocator: std.mem.Allocator, dimensions: Dimensions) !State {
        const root_unit_count = try dimensions.rootUnitCount();
        var species = try allocateFields(SpeciesTotals, allocator, dimensions.species_count);
        errdefer freeFields(SpeciesTotals, allocator, &species);
        var root = try allocateFields(RootFluxes, allocator, root_unit_count);
        errdefer freeFields(RootFluxes, allocator, &root);
        const salts = try allocateFields(SaltFluxes, allocator, root_unit_count);
        return .{
            .allocator = allocator,
            .species_count = dimensions.species_count,
            .root_unit_count = root_unit_count,
            .species = species,
            .root = root,
            .salts = salts,
        };
    }

    pub fn deinit(self: *State) void {
        freeFields(SpeciesTotals, self.allocator, &self.species);
        freeFields(RootFluxes, self.allocator, &self.root);
        freeFields(SaltFluxes, self.allocator, &self.salts);
        self.* = undefined;
    }

    /// UPTAKE.F 342--396. Species totals and root fluxes are always reset;
    /// salt uptake is reset only when dynamic salt chemistry is active.
    pub fn clear(self: *State, salt_mode: SaltMode) !void {
        try validateFields(SpeciesTotals, &self.species, self.species_count);
        try validateFields(RootFluxes, &self.root, self.root_unit_count);
        try validateFields(SaltFluxes, &self.salts, self.root_unit_count);
        clearFields(SpeciesTotals, &self.species);
        clearFields(RootFluxes, &self.root);
        if (salt_mode == .dynamic) clearFields(SaltFluxes, &self.salts);
    }
};

fn allocateFields(comptime T: type, allocator: std.mem.Allocator, count: usize) !T {
    var result: T = undefined;
    var allocated: usize = 0;
    errdefer {
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (allocated > 0) {
                allocated -= 1;
                allocator.free(@field(result, field.name));
            }
        }
    }
    inline for (@typeInfo(T).@"struct".fields) |field| {
        @field(result, field.name) = try allocator.alloc(f64, count);
        @memset(@field(result, field.name), 0);
        allocated += 1;
    }
    return result;
}

fn freeFields(comptime T: type, allocator: std.mem.Allocator, value: *T) void {
    inline for (@typeInfo(T).@"struct".fields) |field|
        allocator.free(@field(value, field.name));
}

fn clearFields(comptime T: type, value: *T) void {
    inline for (@typeInfo(T).@"struct".fields) |field|
        @memset(@field(value, field.name), 0);
}

fn validateFields(comptime T: type, value: *const T, expected_count: usize) !void {
    inline for (@typeInfo(T).@"struct".fields) |field|
        if (@field(value, field.name).len != expected_count)
            return error.InvalidPlantUptakeFluxDimensions;
}

test "UPTAKE reset clears runtime species and ragged root units" {
    const axes = [_]usize{ 1, 3, 2 };
    var state = try State.init(std.testing.allocator, .{
        .species_count = axes.len,
        .soil_layer_count = 4,
        .root_axis_count_by_species = &axes,
    });
    defer state.deinit();
    inline for (@typeInfo(SpeciesTotals).@"struct".fields) |field|
        @memset(@field(state.species, field.name), 3);
    inline for (@typeInfo(RootFluxes).@"struct".fields) |field|
        @memset(@field(state.root, field.name), -2);
    inline for (@typeInfo(SaltFluxes).@"struct".fields) |field|
        @memset(@field(state.salts, field.name), 5);

    try state.clear(.dynamic);

    try std.testing.expectEqual(@as(usize, 24), state.root_unit_count);
    inline for (@typeInfo(SpeciesTotals).@"struct".fields) |field|
        for (@field(state.species, field.name)) |value|
            try std.testing.expectEqual(@as(f64, 0), value);
    inline for (@typeInfo(RootFluxes).@"struct".fields) |field|
        for (@field(state.root, field.name)) |value|
            try std.testing.expectEqual(@as(f64, 0), value);
    inline for (@typeInfo(SaltFluxes).@"struct".fields) |field|
        for (@field(state.salts, field.name)) |value|
            try std.testing.expectEqual(@as(f64, 0), value);
}

test "disabled dynamic salts preserve salt arrays while other uptake resets" {
    var state = try State.init(std.testing.allocator, .{
        .species_count = 1,
        .soil_layer_count = 2,
        .root_axis_count_by_species = &.{2},
    });
    defer state.deinit();
    @memset(state.species.ammonium_uptake_g_n_per_step, 4);
    @memset(state.root.water_uptake_m3_per_step, 6);
    @memset(state.salts.potassium_uptake_mol_per_step, 8);

    try state.clear(.disabled);

    try std.testing.expectEqual(@as(f64, 0), state.species.ammonium_uptake_g_n_per_step[0]);
    try std.testing.expectEqual(@as(f64, 0), state.root.water_uptake_m3_per_step[0]);
    try std.testing.expectEqual(@as(f64, 8), state.salts.potassium_uptake_mol_per_step[0]);
}

test "UPTAKE reset rejects invalid or corrupted runtime dimensions" {
    try std.testing.expectError(
        error.InvalidPlantUptakeFluxDimensions,
        State.init(std.testing.allocator, .{
            .species_count = 2,
            .soil_layer_count = 1,
            .root_axis_count_by_species = &.{1},
        }),
    );
    var state = try State.init(std.testing.allocator, .{
        .species_count = 1,
        .soil_layer_count = 2,
        .root_axis_count_by_species = &.{1},
    });
    defer state.deinit();
    const full = state.root.water_uptake_m3_per_step;
    state.root.water_uptake_m3_per_step = full[0..1];
    try std.testing.expectError(error.InvalidPlantUptakeFluxDimensions, state.clear(.dynamic));
    state.root.water_uptake_m3_per_step = full;
}

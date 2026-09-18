const std = @import("std");

/// Hourly extensive energy ledgers corresponding to OUTSH TRNS/TLES/TSHS/TGHS
/// (ground surface) and TRN/TLE/TSH/TGH (whole ecosystem). All storage is
/// runtime-sized and reset/refreshed once after the converged hourly kernels.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    ground_surface_net_radiation_megajoules: []f64,
    ground_surface_latent_heat_megajoules: []f64,
    ground_surface_sensible_heat_megajoules: []f64,
    ground_surface_storage_heat_megajoules: []f64,
    ecosystem_net_radiation_megajoules: []f64,
    ecosystem_latent_heat_megajoules: []f64,
    ecosystem_sensible_heat_megajoules: []f64,
    ecosystem_storage_heat_megajoules: []f64,
    canopy_water_energy_megajoules: []f64,
    canopy_water_energy_change_megajoules_per_h: []f64,

    noinline fn deinitAllocatedPrefix(self: *State, allocated_count: usize) void {
        var remaining = allocated_count;
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) {
                if (remaining == 0) return;
                self.allocator.free(@field(self, field.name));
                remaining -= 1;
            }
        }
    }

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.EmptyEcosystemEnergyLedger;
        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        var allocated: usize = 0;
        errdefer result.deinitAllocatedPrefix(allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            @field(result, field.name) = try allocator.alloc(f64, cell_count);
            @memset(@field(result, field.name), 0);
            allocated += 1;
        };
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }

    pub fn validateFinite(self: State) !void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) for (@field(self, field.name), 0..) |value, index| {
            if (!std.math.isFinite(value)) {
                std.log.err("non-finite ecosystem energy ledger: field={s} cell={d} value={e}", .{ field.name, index, value });
                return error.NonFiniteEcosystemEnergyLedger;
            }
        };
    }
};

test "ecosystem energy ledger releases every partial allocation prefix" {
    const allocation_count = comptime count: {
        var count: usize = 0;
        for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) count += 1;
        }
        break :count count;
    };

    for (0..allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            State.init(failing.allocator(), 2),
        );
    }
}

pub const Inputs = struct {
    cell_area_m2: []const f64,
    ground_net_radiation_megajoules_per_m2: []const f64,
    ground_latent_heat_megajoules_per_m2: []const f64,
    /// Remaining `TLES` components that the surface energy residual does not
    /// carry: the litter internal pore-vapor <-> liquid/solid equilibrium
    /// latent heat inside legacy `EFLXR2` (`watsub.f:3231`) and the topsoil
    /// lane's latent heat, legacy `EFLXG` (`watsub.f:2894`). WATSUB publishes
    /// `HEATE=EFLXG+EFLXR+EFLXW` (`watsub.f:4185`) and REDIST reduces exactly
    /// that into `TLES` (`redist.f:10629`), so omitting these made the reported
    /// ground latent heat structurally one-sided: only the atmospheric
    /// evaporation lane could ever appear, never the condensation that legacy
    /// reports through the equilibrium terms.
    ///
    /// This is a reporting completion only. Every conservation gate keeps
    /// consuming `ground_latent_heat_megajoules_per_m2` unchanged, and these
    /// components are already independently audited by their own owners (the
    /// surface endpoint-reference heat ledger and the topsoil atmospheric heat
    /// ledger respectively), so they must not be added to any energy balance.
    ground_latent_heat_outside_surface_residual_megajoules_per_m2: []const f64,
    ground_sensible_heat_megajoules_per_m2: []const f64,
    ground_storage_heat_megajoules_per_m2: []const f64,
    species_count: usize,
    canopy_net_radiation_megajoules: []const f64,
    canopy_latent_heat_megajoules: []const f64,
    canopy_sensible_heat_megajoules: []const f64,
    canopy_storage_heat_megajoules: []const f64,
    canopy_convective_water_heat_megajoules: []const f64,
    standing_dead_net_radiation_megajoules: []const f64,
    standing_dead_latent_heat_megajoules: []const f64,
    standing_dead_sensible_heat_megajoules: []const f64,
    standing_dead_storage_heat_megajoules: []const f64,
    standing_dead_convective_water_heat_megajoules: []const f64,
};

pub fn refresh(state: *State, inputs: Inputs) !void {
    if (inputs.species_count == 0) return error.InvalidEcosystemEnergySpeciesCount;
    inline for (.{ inputs.cell_area_m2, inputs.ground_net_radiation_megajoules_per_m2, inputs.ground_latent_heat_megajoules_per_m2, inputs.ground_latent_heat_outside_surface_residual_megajoules_per_m2, inputs.ground_sensible_heat_megajoules_per_m2, inputs.ground_storage_heat_megajoules_per_m2 }) |values| if (values.len != state.cell_count) return error.EcosystemEnergyCellDimensionMismatch;
    const plants = try std.math.mul(usize, state.cell_count, inputs.species_count);
    inline for (.{ inputs.canopy_net_radiation_megajoules, inputs.canopy_latent_heat_megajoules, inputs.canopy_sensible_heat_megajoules, inputs.canopy_storage_heat_megajoules, inputs.canopy_convective_water_heat_megajoules, inputs.standing_dead_net_radiation_megajoules, inputs.standing_dead_latent_heat_megajoules, inputs.standing_dead_sensible_heat_megajoules, inputs.standing_dead_storage_heat_megajoules, inputs.standing_dead_convective_water_heat_megajoules }) |values| if (values.len != plants) return error.EcosystemEnergyPlantDimensionMismatch;

    for (0..state.cell_count) |cell| {
        const area = inputs.cell_area_m2[cell];
        if (!std.math.isFinite(area) or area <= 0) return error.InvalidEcosystemEnergyCellArea;
        const ground_net = inputs.ground_net_radiation_megajoules_per_m2[cell] * area;
        // Exact legacy TLES composition: the atmospheric lane plus the
        // equilibrium/topsoil lanes documented on the input field above.
        const ground_latent = (inputs.ground_latent_heat_megajoules_per_m2[cell] +
            inputs.ground_latent_heat_outside_surface_residual_megajoules_per_m2[cell]) * area;
        const ground_sensible = inputs.ground_sensible_heat_megajoules_per_m2[cell] * area;
        const ground_storage = inputs.ground_storage_heat_megajoules_per_m2[cell] * area;
        state.ground_surface_net_radiation_megajoules[cell] = ground_net;
        state.ground_surface_latent_heat_megajoules[cell] = ground_latent;
        state.ground_surface_sensible_heat_megajoules[cell] = ground_sensible;
        state.ground_surface_storage_heat_megajoules[cell] = ground_storage;
        var ecosystem_net = ground_net;
        var ecosystem_latent = ground_latent;
        var ecosystem_sensible = ground_sensible;
        var ecosystem_storage = ground_storage;
        for (cell * inputs.species_count..(cell + 1) * inputs.species_count) |plant| {
            inline for (.{ inputs.canopy_net_radiation_megajoules[plant], inputs.canopy_latent_heat_megajoules[plant], inputs.canopy_sensible_heat_megajoules[plant], inputs.canopy_storage_heat_megajoules[plant], inputs.canopy_convective_water_heat_megajoules[plant], inputs.standing_dead_net_radiation_megajoules[plant], inputs.standing_dead_latent_heat_megajoules[plant], inputs.standing_dead_sensible_heat_megajoules[plant], inputs.standing_dead_storage_heat_megajoules[plant], inputs.standing_dead_convective_water_heat_megajoules[plant] }) |value| if (!std.math.isFinite(value)) return error.NonFiniteEcosystemEnergyInput;
            ecosystem_net += inputs.canopy_net_radiation_megajoules[plant] + inputs.standing_dead_net_radiation_megajoules[plant];
            ecosystem_latent += inputs.canopy_latent_heat_megajoules[plant] + inputs.standing_dead_latent_heat_megajoules[plant];
            ecosystem_sensible += inputs.canopy_sensible_heat_megajoules[plant] + inputs.standing_dead_sensible_heat_megajoules[plant];
            // Exact EXTRACT convention: TGH -= HFLXC - VFLXC.
            ecosystem_storage -= inputs.canopy_storage_heat_megajoules[plant] - inputs.canopy_convective_water_heat_megajoules[plant];
            ecosystem_storage -= inputs.standing_dead_storage_heat_megajoules[plant] - inputs.standing_dead_convective_water_heat_megajoules[plant];
        }
        state.ecosystem_net_radiation_megajoules[cell] = ecosystem_net;
        state.ecosystem_latent_heat_megajoules[cell] = ecosystem_latent;
        state.ecosystem_sensible_heat_megajoules[cell] = ecosystem_sensible;
        state.ecosystem_storage_heat_megajoules[cell] = ecosystem_storage;
    }
    try state.validateFinite();
}

test "energy ledger reproduces REDIST ground and EXTRACT ecosystem accumulation" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try refresh(&state, .{
        .cell_area_m2 = &.{10},
        .ground_net_radiation_megajoules_per_m2 = &.{1},
        .ground_latent_heat_megajoules_per_m2 = &.{2},
        .ground_latent_heat_outside_surface_residual_megajoules_per_m2 = &.{0},
        .ground_sensible_heat_megajoules_per_m2 = &.{3},
        .ground_storage_heat_megajoules_per_m2 = &.{4},
        .species_count = 2,
        .canopy_net_radiation_megajoules = &.{ 1, 2 },
        .canopy_latent_heat_megajoules = &.{ 3, 4 },
        .canopy_sensible_heat_megajoules = &.{ 5, 6 },
        .canopy_storage_heat_megajoules = &.{ 7, 8 },
        .canopy_convective_water_heat_megajoules = &.{ 0.5, 1 },
        .standing_dead_net_radiation_megajoules = &.{ 0.1, 0.2 },
        .standing_dead_latent_heat_megajoules = &.{ 0.3, 0.4 },
        .standing_dead_sensible_heat_megajoules = &.{ 0.5, 0.6 },
        .standing_dead_storage_heat_megajoules = &.{ 0.7, 0.8 },
        .standing_dead_convective_water_heat_megajoules = &.{ 0.05, 0.1 },
    });
    try std.testing.expectEqual(@as(f64, 10), state.ground_surface_net_radiation_megajoules[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 13.3), state.ecosystem_net_radiation_megajoules[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 27.7), state.ecosystem_latent_heat_megajoules[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 42.1), state.ecosystem_sensible_heat_megajoules[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 25.15), state.ecosystem_storage_heat_megajoules[0], 1e-14);
}

// Legacy `TLES` is `HEATE=EFLXG+EFLXR+EFLXW` (`watsub.f:4185`,
// `redist.f:10629`), and each term includes its internal pore-vapor <->
// liquid/solid equilibrium component, whose sign convention is
// "condensation(+ve) or evaporation(-ve)" (`watsub.f:1265`). Before this lane
// existed the reported ground latent heat could only ever be an atmospheric
// evaporation loss, so the published column was structurally one-sided: no
// input combination could report net condensation into the ground surface
// while the atmospheric lane was evaporating.
//
// Reverting the sum in `refresh` makes the second expectation below reproduce
// the first, so this test fails without the fix rather than passing either
// way.
test "reported ground latent heat is two-sided once the equilibrium and topsoil lanes are included" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    const zero_plant: []const f64 = &.{0};
    // A representative winter hour: the atmospheric lane evaporates a little
    // while the internal equilibrium plus topsoil lanes condense much more.
    const inputs: Inputs = .{
        .cell_area_m2 = &.{4},
        .ground_net_radiation_megajoules_per_m2 = &.{0},
        .ground_latent_heat_megajoules_per_m2 = &.{-0.25},
        .ground_latent_heat_outside_surface_residual_megajoules_per_m2 = &.{0.75},
        .ground_sensible_heat_megajoules_per_m2 = &.{0},
        .ground_storage_heat_megajoules_per_m2 = &.{0},
        .species_count = 1,
        .canopy_net_radiation_megajoules = zero_plant,
        .canopy_latent_heat_megajoules = zero_plant,
        .canopy_sensible_heat_megajoules = zero_plant,
        .canopy_storage_heat_megajoules = zero_plant,
        .canopy_convective_water_heat_megajoules = zero_plant,
        .standing_dead_net_radiation_megajoules = zero_plant,
        .standing_dead_latent_heat_megajoules = zero_plant,
        .standing_dead_sensible_heat_megajoules = zero_plant,
        .standing_dead_storage_heat_megajoules = zero_plant,
        .standing_dead_convective_water_heat_megajoules = zero_plant,
    };
    try refresh(&state, inputs);
    // (-0.25 + 0.75) * 4 = +2.0: reported condensation, which the residual
    // lane alone can never produce.
    try std.testing.expectApproxEqAbs(
        @as(f64, 2),
        state.ground_surface_latent_heat_megajoules[0],
        1e-14,
    );
    try std.testing.expect(state.ground_surface_latent_heat_megajoules[0] > 0);
    try std.testing.expectApproxEqAbs(
        @as(f64, 2),
        state.ecosystem_latent_heat_megajoules[0],
        1e-14,
    );

    // The atmospheric residual lane in isolation stays negative, proving the
    // sign change comes from the newly included legacy components and not from
    // a relabelled existing term.
    var residual_only = inputs;
    residual_only.ground_latent_heat_outside_surface_residual_megajoules_per_m2 = &.{0};
    try refresh(&state, residual_only);
    try std.testing.expectApproxEqAbs(
        @as(f64, -1),
        state.ground_surface_latent_heat_megajoules[0],
        1e-14,
    );
}

const std = @import("std");

pub const Species = enum(u8) {
    carbon_dioxide,
    methane,
    oxygen,
    nitrogen,
    nitrous_oxide,
    ammonia,
    hydrogen,
};

pub const species_count = @typeInfo(Species).@"enum".fields.len;

pub fn massIndex(cell: usize, species: Species, cell_count: usize) !usize {
    if (cell >= cell_count) return error.GasTransportCellIndexOutOfBounds;
    return try std.math.add(usize, try std.math.mul(usize, cell, species_count), @intFromEnum(species));
}

/// ecosys stores each gas as the mass of its tracked element: C for CO2/CH4,
/// O2 as molecular oxygen, N for N2/N2O/NH3, and H2 as molecular hydrogen.
pub const g_per_mol_tracked = [species_count]f64{ 12, 12, 32, 28, 28, 14, 2 };
pub const atmospheric_boundary_multiplier = [species_count]f64{ 0.74, 1.04, 0.83, 0.86, 0.74, 1.02, 2.08 };

pub const SurfaceSolubilityParameters = struct {
    reference_water_to_air: [species_count]f64,
    log_intercept: [species_count]f64,
    temperature_coefficient_per_c: [species_count]f64,
};

/// HOUR1 L=0 temperature-dependent gas solubilities. Array order follows
/// `Species`, retaining the distinct NH3 coefficient even though STARTE does
/// not seed aqueous litter NH3.
pub fn surfaceSolubilityWaterToAir(temperature_k: f64, parameters: SurfaceSolubilityParameters) ![species_count]f64 {
    if (!std.math.isFinite(temperature_k) or temperature_k <= 0) return error.InvalidSurfaceGasTemperature;
    const temperature_c = temperature_k - 273.15;
    var result: [species_count]f64 = undefined;
    for (&result, parameters.reference_water_to_air, parameters.log_intercept, parameters.temperature_coefficient_per_c) |*value, reference, intercept, coefficient| {
        if (!std.math.isFinite(reference) or reference < 0 or !std.math.isFinite(intercept) or !std.math.isFinite(coefficient)) return error.InvalidSurfaceGasSolubilityParameter;
        value.* = reference * @exp(intercept - coefficient * temperature_c);
        if (!std.math.isFinite(value.*) or value.* < 0) return error.NonFiniteSurfaceGasSolubility;
    }
    return result;
}

/// STARTE L=0 gas initialization from runtime atmospheric concentrations.
/// Initial aqueous volume is passed explicitly because the source uses FC(0)
/// rather than assuming current liquid storage. NH3 aqueous mass starts at 0.
pub fn initializeSurfaceCell(state: *State, cell: usize, air_volume_m3: f64, initial_water_volume_m3: f64, temperature_k: f64, atmospheric_concentration_g_per_m3: [species_count]f64, solubility_parameters: SurfaceSolubilityParameters) !void {
    if (cell >= state.cell_count or !std.math.isFinite(air_volume_m3) or air_volume_m3 < 0 or !std.math.isFinite(initial_water_volume_m3) or initial_water_volume_m3 < 0) return error.InvalidSurfaceGasInitialization;
    const solubility = try surfaceSolubilityWaterToAir(temperature_k, solubility_parameters);
    var gaseous: [species_count]f64 = undefined;
    var dissolved: [species_count]f64 = undefined;
    for (&gaseous, &dissolved, atmospheric_concentration_g_per_m3, solubility, 0..) |*gas_mass, *water_mass, concentration, ratio, species_index| {
        if (!std.math.isFinite(concentration) or concentration < 0) return error.InvalidSurfaceGasInitialization;
        gas_mass.* = concentration * air_volume_m3;
        water_mass.* = if (species_index == @intFromEnum(Species.ammonia)) 0 else concentration * ratio * initial_water_volume_m3;
        if (!std.math.isFinite(gas_mass.*) or !std.math.isFinite(water_mass.*)) return error.NonFiniteSurfaceGasInitialization;
    }
    const first = cell * species_count;
    state.air_volume_m3[cell] = air_volume_m3;
    state.temperature_k[cell] = temperature_k;
    @memcpy(state.gaseous_mass_g[first .. first + species_count], &gaseous);
    @memcpy(state.dissolved_mass_g[first .. first + species_count], &dissolved);
    @memset(state.macropore_dissolved_mass_g[first .. first + species_count], 0);
    @memset(state.band_dissolved_mass_g[first .. first + species_count], 0);
}

/// `starte.f` lines 1411--1433 for one soil layer (L>=1). The surface litter cell
/// L=0 uses `initializeSurfaceCell` instead.
///
/// Two source details are easy to lose and are asserted by the tests:
///  - Dissolved oxygen is suppressed when the layer's upper face lies at or
///    below the water table (`CDPTH(L-1) < DTBLZ` is the seeding condition).
///    The suppression is oxygen-only; every other species is seeded at all
///    depths, because saturated soil is anoxic rather than gas-free.
///  - Aqueous ammonia is never seeded, matching the surface cell.
///
/// `ionic_strength` is the oracle's `CSTR1` for the layer, and
/// `activity_coefficient` holds `ACO2X`/`ACH4X`/`AOXYX`/`AN2GX`/`AN2OX`/NH3/
/// `AH2GX` in `Species` order. Each dissolved concentration is divided by
/// `exp(A * CSTR1)`, which is exactly 1 for non-saline soil where `CSTR1` is 0.
pub fn initializeSoilLayerCell(
    state: *State,
    layer_cell: usize,
    air_volume_m3: f64,
    water_volume_m3: f64,
    layer_top_depth_m: f64,
    water_table_depth_m: f64,
    mean_annual_temperature_k: f64,
    atmospheric_concentration_g_per_m3: [species_count]f64,
    solubility_parameters: SurfaceSolubilityParameters,
    ionic_strength: f64,
    activity_coefficient: [species_count]f64,
) !void {
    if (layer_cell >= state.cell_count) return error.SoilGasLayerIndexOutOfBounds;
    inline for (.{ air_volume_m3, water_volume_m3, layer_top_depth_m, water_table_depth_m, ionic_strength }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSoilGasInitialization;
    if (air_volume_m3 < 0 or water_volume_m3 < 0 or ionic_strength < 0) return error.InvalidSoilGasInitialization;
    const solubility = try surfaceSolubilityWaterToAir(mean_annual_temperature_k, solubility_parameters);
    const above_water_table = layer_top_depth_m < water_table_depth_m;
    for (0..species_count) |species| {
        const index = layer_cell * species_count + species;
        const concentration = atmospheric_concentration_g_per_m3[species];
        if (!std.math.isFinite(concentration) or concentration < 0) return error.InvalidSoilGasInitialization;
        const activity = activity_coefficient[species];
        if (!std.math.isFinite(activity)) return error.InvalidSoilGasInitialization;
        const ionic_divisor = @exp(activity * ionic_strength);
        if (!std.math.isFinite(ionic_divisor) or ionic_divisor <= 0) return error.NonFiniteSoilGasInitialization;
        state.gaseous_mass_g[index] = concentration * air_volume_m3;
        const suppressed = species == @intFromEnum(Species.ammonia) or
            (species == @intFromEnum(Species.oxygen) and !above_water_table);
        state.dissolved_mass_g[index] = if (suppressed)
            0
        else
            concentration * solubility[species] / ionic_divisor * water_volume_m3;
        inline for (.{ state.gaseous_mass_g[index], state.dissolved_mass_g[index] }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.NonFiniteSoilGasInitialization;
    }
}

/// `starte.f:32--34` PARAMETER activity coefficients in `Species` order:
/// ACO2X, ACH4X, AOXYX, AN2GX, AN2OX, ANH3X, AH2GX. Every slot now carries its
/// own source value. The ammonia slot is currently unread because aqueous NH3
/// is never seeded, but it holds ANH3X=0.07 rather than filler so the table
/// cannot mislead a future caller that lifts the NH3 suppression. See
/// `docs/traceability/starte_activity_coefficient_h2_correction.md`.
pub const starte_activity_coefficient = [species_count]f64{ 0.14, 0.14, 0.31, 0.23, 0.23, 0.07, 0.14 };

const test_solubility: SurfaceSolubilityParameters = .{
    .reference_water_to_air = .{ 0.7391, 0.03156, 0.02925, 0.01510, 0.5241, 285.2, 0.03156 },
    .log_intercept = .{ 0.843, 0.597, 0.516, 0.456, 0.897, 0.513, 0.597 },
    .temperature_coefficient_per_c = .{ 0.0281, 0.0199, 0.0172, 0.0152, 0.0299, 0.0171, 0.0199 },
};
const test_atmosphere = [species_count]f64{ 0.2144, 0.00096, 300.3, 975, 0.0001, 0.00001, 0.000001 };

test "soil layer above the water table receives dissolved oxygen" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try initializeSoilLayerCell(&state, 0, 0.15, 0.25, 0.1, 1.5, 279.65, test_atmosphere, test_solubility, 0, starte_activity_coefficient);
    const oxygen = @intFromEnum(Species.oxygen);
    try std.testing.expectApproxEqRel(@as(f64, 300.3 * 0.15), state.gaseous_mass_g[oxygen], 1e-15);
    try std.testing.expectApproxEqRel(
        300.3 * 0.02925 * @exp(0.516 - 0.0172 * 6.5) * 0.25,
        state.dissolved_mass_g[oxygen],
        1e-12,
    );
}

test "soil layer at or below the water table starts anoxic in the aqueous phase only" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    // Upper face exactly at the water table: the source condition is a strict
    // `<`, so this layer must be suppressed.
    try initializeSoilLayerCell(&state, 0, 0.02, 0.4, 1.5, 1.5, 279.65, test_atmosphere, test_solubility, 0, starte_activity_coefficient);
    try std.testing.expectEqual(@as(f64, 0), state.dissolved_mass_g[@intFromEnum(Species.oxygen)]);
    // Gaseous oxygen is unaffected, and other dissolved species are still seeded.
    try std.testing.expect(state.gaseous_mass_g[@intFromEnum(Species.oxygen)] > 0);
    try std.testing.expect(state.dissolved_mass_g[@intFromEnum(Species.carbon_dioxide)] > 0);
    try std.testing.expect(state.dissolved_mass_g[@intFromEnum(Species.nitrogen)] > 0);
}

test "aqueous ammonia is never seeded in soil layers" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try initializeSoilLayerCell(&state, 0, 0.1, 0.3, 0, 5, 279.65, test_atmosphere, test_solubility, 0, starte_activity_coefficient);
    try std.testing.expectEqual(@as(f64, 0), state.dissolved_mass_g[@intFromEnum(Species.ammonia)]);
    try std.testing.expect(state.gaseous_mass_g[@intFromEnum(Species.ammonia)] > 0);
}

test "ionic strength divides dissolved mass and is a no-op when zero" {
    var fresh = try State.init(std.testing.allocator, 1);
    defer fresh.deinit();
    var saline = try State.init(std.testing.allocator, 1);
    defer saline.deinit();
    try initializeSoilLayerCell(&fresh, 0, 0.15, 0.25, 0.1, 1.5, 279.65, test_atmosphere, test_solubility, 0, starte_activity_coefficient);
    try initializeSoilLayerCell(&saline, 0, 0.15, 0.25, 0.1, 1.5, 279.65, test_atmosphere, test_solubility, 2.0, starte_activity_coefficient);
    const oxygen = @intFromEnum(Species.oxygen);
    // Zero ionic strength must leave the plain Henry expression untouched, which
    // is why this term is invisible in the non-saline Ottawa example.
    try std.testing.expectApproxEqRel(
        300.3 * 0.02925 * @exp(0.516 - 0.0172 * 6.5) * 0.25,
        fresh.dissolved_mass_g[oxygen],
        1e-12,
    );
    // Saline soil divides by exp(AOXYX * CSTR1) with AOXYX = 0.31.
    try std.testing.expectApproxEqRel(
        fresh.dissolved_mass_g[oxygen] / @exp(0.31 * 2.0),
        saline.dissolved_mass_g[oxygen],
        1e-12,
    );
    // The gaseous phase carries no ionic-strength term.
    try std.testing.expectEqual(fresh.gaseous_mass_g[oxygen], saline.gaseous_mass_g[oxygen]);
    // Each species uses its own coefficient, so CO2 (0.14) is divided less than
    // oxygen (0.31) at the same ionic strength.
    const co2 = @intFromEnum(Species.carbon_dioxide);
    try std.testing.expectApproxEqRel(
        fresh.dissolved_mass_g[co2] / @exp(0.14 * 2.0),
        saline.dissolved_mass_g[co2],
        1e-12,
    );
}

test "negative ionic strength is rejected" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try std.testing.expectError(error.InvalidSoilGasInitialization, initializeSoilLayerCell(&state, 0, 0.1, 0.3, 0, 5, 279.65, test_atmosphere, test_solubility, -1, starte_activity_coefficient));
    try std.testing.expectError(error.NonFiniteSoilGasInitialization, initializeSoilLayerCell(&state, 0, 0.1, 0.3, 0, 5, 279.65, test_atmosphere, test_solubility, std.math.nan(f64), starte_activity_coefficient));
}

test "soil layer gas seeding rejects invalid geometry and layer indices" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try std.testing.expectError(error.SoilGasLayerIndexOutOfBounds, initializeSoilLayerCell(&state, 1, 0.1, 0.3, 0, 5, 279.65, test_atmosphere, test_solubility, 0, starte_activity_coefficient));
    try std.testing.expectError(error.InvalidSoilGasInitialization, initializeSoilLayerCell(&state, 0, -1, 0.3, 0, 5, 279.65, test_atmosphere, test_solubility, 0, starte_activity_coefficient));
    try std.testing.expectError(error.NonFiniteSoilGasInitialization, initializeSoilLayerCell(&state, 0, 0.1, std.math.nan(f64), 0, 5, 279.65, test_atmosphere, test_solubility, 0, starte_activity_coefficient));
}

pub const Face = struct {
    first_cell: usize,
    second_cell: usize,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    air_volume_m3: []f64,
    temperature_k: []f64,
    water_vapor_mol: []f64,
    /// Cell-major gas inventories in grams of the tracked element.
    gaseous_mass_g: []f64,
    dissolved_mass_g: []f64,
    /// Dissolved inventory carried by runtime soil macropore water.
    macropore_dissolved_mass_g: []f64,
    /// Band-water inventory; currently used by ammonia, retained as a full
    /// species-major buffer so kernels remain uniform and GPU-portable.
    band_dissolved_mass_g: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroGasTransportCellCount;
        const air = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(air);
        const temperature = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(temperature);
        const vapor = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(vapor);
        const n = try std.math.mul(usize, cell_count, species_count);
        const gaseous = try allocator.alloc(f64, n);
        errdefer allocator.free(gaseous);
        const dissolved = try allocator.alloc(f64, n);
        errdefer allocator.free(dissolved);
        const macropore_dissolved = try allocator.alloc(f64, n);
        errdefer allocator.free(macropore_dissolved);
        const band_dissolved = try allocator.alloc(f64, n);
        errdefer allocator.free(band_dissolved);
        @memset(air, 0);
        @memset(temperature, 0);
        @memset(vapor, 0);
        @memset(gaseous, 0);
        @memset(dissolved, 0);
        @memset(macropore_dissolved, 0);
        @memset(band_dissolved, 0);
        return .{ .allocator = allocator, .cell_count = cell_count, .air_volume_m3 = air, .temperature_k = temperature, .water_vapor_mol = vapor, .gaseous_mass_g = gaseous, .dissolved_mass_g = dissolved, .macropore_dissolved_mass_g = macropore_dissolved, .band_dissolved_mass_g = band_dissolved };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.band_dissolved_mass_g);
        self.allocator.free(self.macropore_dissolved_mass_g);
        self.allocator.free(self.dissolved_mass_g);
        self.allocator.free(self.gaseous_mass_g);
        self.allocator.free(self.water_vapor_mol);
        self.allocator.free(self.temperature_k);
        self.allocator.free(self.air_volume_m3);
        self.* = undefined;
    }

    pub fn clone(
        self: *const State,
        allocator: std.mem.Allocator,
    ) !State {
        var result = try State.init(allocator, self.cell_count);
        errdefer result.deinit();
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64)
                @memcpy(@field(&result, field.name), @field(self, field.name));
        }
        return result;
    }

    pub fn gaseousMasses(self: *State, cell: usize) ![]f64 {
        if (cell >= self.cell_count) return error.GasTransportCellIndexOutOfBounds;
        return self.gaseous_mass_g[cell * species_count .. (cell + 1) * species_count];
    }

    pub fn gaseousMassesConst(self: *const State, cell: usize) ![]const f64 {
        if (cell >= self.cell_count) return error.GasTransportCellIndexOutOfBounds;
        return self.gaseous_mass_g[cell * species_count .. (cell + 1) * species_count];
    }

    pub fn dissolvedMass(self: *State, cell: usize, species: Species) !*f64 {
        return &self.dissolved_mass_g[try massIndex(cell, species, self.cell_count)];
    }

    pub fn dissolvedMassConst(self: *const State, cell: usize, species: Species) !f64 {
        return self.dissolved_mass_g[try massIndex(cell, species, self.cell_count)];
    }

    /// Validates allocation dimensions before any field is indexed.
    pub fn validateShape(self: *const State) !void {
        const mass_count = std.math.mul(usize, self.cell_count, species_count) catch
            return error.CoupledGasStateSizeMismatch;
        if (self.cell_count == 0 or
            self.air_volume_m3.len != self.cell_count or
            self.temperature_k.len != self.cell_count or
            self.water_vapor_mol.len != self.cell_count or
            self.gaseous_mass_g.len != mass_count or
            self.dissolved_mass_g.len != mass_count or
            self.macropore_dissolved_mass_g.len != mass_count or
            self.band_dissolved_mass_g.len != mass_count)
        {
            return error.CoupledGasStateSizeMismatch;
        }
    }

    pub fn validateFinite(self: *const State) !void {
        try self.validateShape();
        inline for (@typeInfo(State).@"struct".fields) |declared| {
            if (declared.type == []f64) {
                for (@field(self, declared.name), 0..) |value, index| {
                    if (!std.math.isFinite(value)) {
                        std.log.warn(
                            "non-finite gas state: field={s} index={d} value={e}",
                            .{ declared.name, index, value },
                        );
                        return error.NonFiniteGasTransportState;
                    }
                    if (value < 0) {
                        std.log.warn(
                            "negative gas state: field={s} index={d} value={e}",
                            .{ declared.name, index, value },
                        );
                        return error.NegativeGasTransportState;
                    }
                }
            }
        }
        for (self.temperature_k) |temperature_k| {
            if (temperature_k <= 0) return error.InvalidGasTransportTemperature;
        }
    }
};

/// Penman linear-reduction expression used for litter and soil gas diffusion.
pub fn airFilledDiffusionGeometry(air_filled_porosity_m3_per_m3: f64, tortuosity: f64, total_porosity_m3_per_m3: f64, face_area_m2: f64, path_length_m: f64) !f64 {
    const v = [_]f64{ air_filled_porosity_m3_per_m3, tortuosity, total_porosity_m3_per_m3, face_area_m2, path_length_m };
    for (v) |x| if (!std.math.isFinite(x) or x < 0) return error.InvalidGasDiffusionGeometry;
    if (total_porosity_m3_per_m3 == 0 or path_length_m == 0) return error.InvalidGasDiffusionGeometry;
    return air_filled_porosity_m3_per_m3 * tortuosity * air_filled_porosity_m3_per_m3 / total_porosity_m3_per_m3 * face_area_m2 / path_length_m;
}

pub fn seriesConductance(interior_m3_per_step: f64, boundary_m3_per_step: f64) !f64 {
    if (!std.math.isFinite(interior_m3_per_step) or interior_m3_per_step < 0 or !std.math.isFinite(boundary_m3_per_step) or boundary_m3_per_step < 0) return error.InvalidGasConductance;
    return seriesConductanceFromValidatedInputs(interior_m3_per_step, boundary_m3_per_step);
}

pub fn seriesConductanceFromValidatedInputs(interior_m3_per_step: f64, boundary_m3_per_step: f64) f64 {
    const lower = @min(interior_m3_per_step, boundary_m3_per_step);
    const upper = @max(interior_m3_per_step, boundary_m3_per_step);
    return if (lower > 0) lower / (1 + lower / upper) else 0;
}

test "series conductance remains finite for an effectively open outer boundary" {
    const result = try seriesConductance(0.25, std.math.floatMax(f64));
    try std.testing.expectEqual(@as(f64, 0.25), result);
}

/// Conservative gaseous diffusion across one grid face. Positive flux moves
/// first -> second. Face coloring makes this kernel parallel without atomics.
///
/// `minimum_air_volume_m3` carries each side's own legacy
/// `ZEROS2(NY,NX) = ZERO2 * DH * DV` gaseous minimum from `starts.f:94,270`.
/// The source tests the two cells against their own horizontal cell's value,
/// so the pair is kept separate rather than collapsed. See
/// `calculateFaceDiffusiveFluxesGFromValidatedInputs` for the oracle branch.
pub fn calculateFaceDiffusiveFluxesG(state: *const State, face: Face, conductance_m3_per_step: []const f64, minimum_air_volume_m3: [2]f64, output_flux_g: []f64) !void {
    if (face.first_cell >= state.cell_count or face.second_cell >= state.cell_count or face.first_cell == face.second_cell) return error.InvalidGasTransportFace;
    if (conductance_m3_per_step.len != species_count or output_flux_g.len != species_count) return error.GasSpeciesCountMismatch;
    for (minimum_air_volume_m3) |minimum|
        if (!std.math.isFinite(minimum) or minimum < 0) return error.InvalidGasTransportState;
    const first = try state.gaseousMassesConst(face.first_cell);
    const second = try state.gaseousMassesConst(face.second_cell);
    const first_air = state.air_volume_m3[face.first_cell];
    const second_air = state.air_volume_m3[face.second_cell];
    if (!std.math.isFinite(first_air) or first_air < 0 or !std.math.isFinite(second_air) or second_air < 0) return error.InvalidGasTransportState;
    for (first, second, conductance_m3_per_step) |first_mass, second_mass, conductance| {
        if (!std.math.isFinite(first_mass) or first_mass < 0 or !std.math.isFinite(second_mass) or second_mass < 0 or !std.math.isFinite(conductance) or conductance < 0) return error.InvalidGasTransportState;
    }
    return calculateFaceDiffusiveFluxesGFromValidatedInputs(state, face, conductance_m3_per_step, minimum_air_volume_m3, output_flux_g);
}

/// Solver-only form. The coupled solver validates geometry and conductance once
/// and validates each nonlinear candidate once before evaluating its faces.
///
/// `ecosys_f77/trnsfr.f:5303-5306` admits gaseous diffusion across a face only
/// when BOTH cells clear two independent floors:
///
///     IF(THETPM(M,N3,N2,N1).GT.THETX
///    2.AND.THETPM(M,N6,N5,N4).GT.THETX
///    3.AND.VOLPM(M,N3,N2,N1).GT.ZEROS2(N2,N1)
///    4.AND.VOLPM(M,N6,N5,N4).GT.ZEROS2(N5,N4))THEN
///
/// There is no `ELSE`: below either floor the source performs no gaseous
/// diffusion at all. `face_assembly.zig` translates the dimensionless `THETX`
/// half; `minimum_air_volume_m3` is the volumetric `ZEROS2` half, which the
/// porosity test does not imply -- a layer thinner than
/// `minimum_carrier_volume_m3_per_m2` (the deck permits 1e-9 m) can hold a
/// healthy air-filled porosity over an air volume far below `ZEROS2`. Without
/// this floor `first_mass / first_air` is evaluated at an unresolvable carrier
/// volume and hands the enclosing fixed-point map a `conductance / air`
/// derivative no nonlinear solver can close.
pub fn calculateFaceDiffusiveFluxesGFromValidatedInputs(state: *const State, face: Face, conductance_m3_per_step: []const f64, minimum_air_volume_m3: [2]f64, output_flux_g: []f64) !void {
    const first_air = state.air_volume_m3[face.first_cell];
    const second_air = state.air_volume_m3[face.second_cell];
    if (first_air <= minimum_air_volume_m3[0] or second_air <= minimum_air_volume_m3[1]) {
        @memset(output_flux_g, 0);
        return;
    }
    const first = state.gaseous_mass_g[face.first_cell * species_count ..][0..species_count];
    const second = state.gaseous_mass_g[face.second_cell * species_count ..][0..species_count];
    for (first, second, conductance_m3_per_step, output_flux_g) |first_mass, second_mass, conductance, *flux| {
        const first_concentration = first_mass / first_air;
        const second_concentration = second_mass / second_air;
        flux.* = std.math.clamp(conductance * (first_concentration - second_concentration), -second_mass, first_mass);
        if (!std.math.isFinite(flux.*)) return error.NonFiniteGasTransportFlux;
    }
}

pub fn state_updateFaceFluxesG(state: *State, face: Face, flux_g: []const f64) !void {
    if (face.first_cell >= state.cell_count or face.second_cell >= state.cell_count or face.first_cell == face.second_cell) return error.InvalidGasTransportFace;
    if (flux_g.len != species_count) return error.GasSpeciesCountMismatch;
    const first = try state.gaseousMasses(face.first_cell);
    const second = try state.gaseousMasses(face.second_cell);
    for (first, second, flux_g) |a, b, flux| if (!std.math.isFinite(flux) or a - flux < 0 or b + flux < 0) return error.InsufficientGasForTransport;
    for (first, second, flux_g) |*a, *b, flux| {
        a.* -= flux;
        b.* += flux;
    }
}

/// Exact bounded TRNSFRS atmospheric diffusion convention. Positive is into
/// the modeled cell. `iteration_fraction` is XNPG (= 1/NPG).
pub fn atmosphericDiffusiveFluxG(cell_mass_g: f64, cell_air_volume_m3: f64, atmospheric_concentration_g_per_m3: f64, conductance_m3_per_step: f64, iteration_fraction: f64) !f64 {
    const v = [_]f64{ cell_mass_g, cell_air_volume_m3, atmospheric_concentration_g_per_m3, conductance_m3_per_step, iteration_fraction };
    for (v) |x| if (!std.math.isFinite(x) or x < 0) return error.InvalidAtmosphericGasInput;
    if (iteration_fraction > 1) return error.InvalidAtmosphericGasInput;
    return atmosphericDiffusiveFluxGFromValidatedInputs(cell_mass_g, cell_air_volume_m3, atmospheric_concentration_g_per_m3, conductance_m3_per_step, iteration_fraction);
}

pub fn atmosphericDiffusiveFluxGFromValidatedInputs(cell_mass_g: f64, cell_air_volume_m3: f64, atmospheric_concentration_g_per_m3: f64, conductance_m3_per_step: f64, iteration_fraction: f64) f64 {
    // TRNSFR scales both the interior and aerodynamic conductances by its gas
    // timestep before taking their series limit (`PARGM=PARG*XNPT` and the
    // `*SGL2` diffusivities). Series conductance is homogeneous, so applying
    // the represented fraction here is exactly the same operation. The
    // equilibrium and donor bounds below carry that fraction independently.
    const requested = conductance_m3_per_step *
        (atmospheric_concentration_g_per_m3 -
            (if (cell_air_volume_m3 > 0) cell_mass_g / cell_air_volume_m3 else 0)) *
        iteration_fraction;
    const equilibrium_change = (atmospheric_concentration_g_per_m3 * cell_air_volume_m3 - cell_mass_g) * iteration_fraction;
    // Bound toward, but never past, atmospheric equilibrium in either
    // direction. The former unconditional `min` was correct only for inward
    // diffusion; on an outward gradient it selected the more-negative
    // equilibrium endpoint and evacuated the pool regardless of conductance.
    return std.math.clamp(
        requested,
        @min(0, equilibrium_change),
        @max(0, equilibrium_change),
    );
}

test "atmospheric gas outflow retains the source conductance magnitude" {
    try std.testing.expectApproxEqAbs(
        @as(f64, -0.1),
        try atmosphericDiffusiveFluxG(1, 1, 0, 0.1, 1),
        8 * std.math.floatEps(f64),
    );
}

test "surface gas initialization reproduces STARTE and HOUR1 solubility" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    const reference = [species_count]f64{ 0.7391, 0.03156, 0.02925, 0.01510, 0.5241, 285.2, 0.03156 };
    const intercept = [species_count]f64{ 0.843, 0.597, 0.516, 0.456, 0.897, 0.513, 0.597 };
    const coefficient = [species_count]f64{ 0.0281, 0.0199, 0.0172, 0.0152, 0.0299, 0.0171, 0.0199 };
    const atmosphere = [species_count]f64{ 0.2, 0.001, 0.3, 0.8, 0.0001, 0.00001, 0.000001 };
    try initializeSurfaceCell(&state, 1, 2, 0.5, 293.15, atmosphere, .{ .reference_water_to_air = reference, .log_intercept = intercept, .temperature_coefficient_per_c = coefficient });
    const first = species_count;
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), state.gaseous_mass_g[first + @intFromEnum(Species.oxygen)], 1e-15);
    const oxygen_solubility = reference[@intFromEnum(Species.oxygen)] * @exp(0.516 - 0.0172 * 20);
    try std.testing.expectApproxEqAbs(atmosphere[@intFromEnum(Species.oxygen)] * oxygen_solubility * 0.5, state.dissolved_mass_g[first + @intFromEnum(Species.oxygen)], 1e-15);
    try std.testing.expectEqual(@as(f64, 0), state.dissolved_mass_g[first + @intFromEnum(Species.ammonia)]);
}

/// Pressure/temperature correction from TRNSFRS. Fluxes are positive into the
/// cell and retain the existing gas mixture composition.
pub fn pressureDrivenFluxesG(air_volume_m3: f64, temperature_k: f64, water_vapor_mol: f64, gaseous_mass_g: []const f64, iteration_fraction: f64, output_flux_g: []f64) !void {
    if (gaseous_mass_g.len != species_count or output_flux_g.len != species_count) return error.GasSpeciesCountMismatch;
    if (!std.math.isFinite(air_volume_m3) or air_volume_m3 < 0 or !std.math.isFinite(temperature_k) or temperature_k <= 0 or !std.math.isFinite(water_vapor_mol) or water_vapor_mol < 0 or !std.math.isFinite(iteration_fraction) or iteration_fraction < 0 or iteration_fraction > 1) return error.InvalidGasPressureInput;
    for (gaseous_mass_g) |mass| {
        if (!std.math.isFinite(mass) or mass < 0) return error.InvalidGasTransportState;
    }
    return pressureDrivenFluxesGFromValidatedInputs(air_volume_m3, temperature_k, water_vapor_mol, gaseous_mass_g, iteration_fraction, output_flux_g);
}

pub fn pressureDrivenFluxesGFromValidatedInputs(air_volume_m3: f64, temperature_k: f64, water_vapor_mol: f64, gaseous_mass_g: []const f64, iteration_fraction: f64, output_flux_g: []f64) !void {
    var actual_mol = water_vapor_mol;
    for (gaseous_mass_g, g_per_mol_tracked) |mass, molar_mass| {
        actual_mol += mass / molar_mass;
    }
    if (actual_mol == 0) {
        @memset(output_flux_g, 0);
        return;
    }
    const capacity_mol = @max(0, 1.2194e4 * air_volume_m3 / temperature_k);
    const bulk_flux_mol = (capacity_mol - actual_mol) * iteration_fraction;
    for (output_flux_g, gaseous_mass_g, g_per_mol_tracked) |*flux, mass, molar_mass| {
        flux.* = bulk_flux_mol * (mass / molar_mass) / actual_mol * molar_mass;
        flux.* = @max(-mass * iteration_fraction, flux.*);
        if (!std.math.isFinite(flux.*)) return error.NonFiniteGasTransportFlux;
    }
}

/// TRNSFRS intercell pressure displacement. The receiving (`second`) cell's
/// temperature, air volume, vapor, and mixture define the bulk displacement;
/// positive flux is first -> second. Inventory clipping replaces the source's
/// dimensionally inconsistent mol-vs-g `AMIN1` bounds while retaining the
/// calculated scientific flux direction and mixture allocation.
pub fn adjacentPressureDrivenFluxesG(first_mass_g: []const f64, second_mass_g: []const f64, second_air_volume_m3: f64, second_temperature_k: f64, second_water_vapor_mol: f64, iteration_fraction: f64, output_flux_g: []f64) !void {
    if (first_mass_g.len != species_count or second_mass_g.len != species_count or output_flux_g.len != species_count) return error.GasSpeciesCountMismatch;
    if (!std.math.isFinite(second_air_volume_m3) or second_air_volume_m3 < 0 or !std.math.isFinite(second_temperature_k) or second_temperature_k <= 0 or !std.math.isFinite(second_water_vapor_mol) or second_water_vapor_mol < 0 or !std.math.isFinite(iteration_fraction) or iteration_fraction < 0 or iteration_fraction > 1) return error.InvalidGasPressureInput;
    for (first_mass_g, second_mass_g) |first, second| {
        if (!std.math.isFinite(first) or first < 0 or !std.math.isFinite(second) or second < 0) return error.InvalidGasTransportState;
    }
    return adjacentPressureDrivenFluxesGFromValidatedInputs(first_mass_g, second_mass_g, second_air_volume_m3, second_temperature_k, second_water_vapor_mol, iteration_fraction, output_flux_g);
}

pub fn adjacentPressureDrivenFluxesGFromValidatedInputs(first_mass_g: []const f64, second_mass_g: []const f64, second_air_volume_m3: f64, second_temperature_k: f64, second_water_vapor_mol: f64, iteration_fraction: f64, output_flux_g: []f64) !void {
    var second_total_mol = second_water_vapor_mol;
    for (second_mass_g, g_per_mol_tracked) |second, molar_mass| {
        second_total_mol += second / molar_mass;
    }
    if (second_total_mol == 0) {
        @memset(output_flux_g, 0);
        return;
    }
    const capacity_mol = @max(0, 1.2194e4 * second_air_volume_m3 / second_temperature_k);
    const bulk_flux_mol = (capacity_mol - second_total_mol) * iteration_fraction;
    for (output_flux_g, first_mass_g, second_mass_g, g_per_mol_tracked) |*flux, first, second, molar_mass| {
        const requested_g = bulk_flux_mol * (second / molar_mass) / second_total_mol * molar_mass;
        // TRNSFR `AMIN1(V*G1,RFL*G)` uses the upstream molar inventory as
        // the numerical upper bound after RFL*G has been converted to grams.
        // Preserve that source behavior exactly; using the full gram mass
        // overstates convection by the tracked molar mass (12--32 times).
        flux.* = std.math.clamp(requested_g, -second, first / molar_mass);
        if (!std.math.isFinite(flux.*)) return error.NonFiniteGasTransportFlux;
    }
}

/// Air-water equilibration equation shared by all seven gases. Positive flux
/// dissolves gaseous mass into water; negative flux volatilizes aqueous mass.
pub fn phaseExchangeFluxG(gaseous_mass_g: f64, dissolved_mass_g: f64, air_volume_m3: f64, water_volume_m3: f64, mass_solubility_ratio: f64, exchange_rate_per_step: f64) !f64 {
    const v = [_]f64{ gaseous_mass_g, dissolved_mass_g, air_volume_m3, water_volume_m3, mass_solubility_ratio, exchange_rate_per_step };
    for (v) |x| if (!std.math.isFinite(x) or x < 0) return error.InvalidGasPhaseExchangeInput;
    return phaseExchangeFluxGFromValidatedInputs(gaseous_mass_g, dissolved_mass_g, air_volume_m3, water_volume_m3, mass_solubility_ratio, exchange_rate_per_step);
}

pub fn phaseExchangeFluxGFromValidatedInputs(gaseous_mass_g: f64, dissolved_mass_g: f64, air_volume_m3: f64, water_volume_m3: f64, mass_solubility_ratio: f64, exchange_rate_per_step: f64) !f64 {
    const equivalent_water_volume = water_volume_m3 * mass_solubility_ratio;
    const total_equivalent_volume = equivalent_water_volume + air_volume_m3;
    if (total_equivalent_volume == 0) return 0;
    const flux = exchange_rate_per_step * (gaseous_mass_g * equivalent_water_volume - dissolved_mass_g * air_volume_m3) / total_equivalent_volume;
    if (!std.math.isFinite(flux)) return error.NonFiniteGasPhaseExchangeFlux;
    return std.math.clamp(flux, -dissolved_mass_g, gaseous_mass_g);
}

/// Supersaturation bubbling calculation from TRNSFRS. Dissolved masses are
/// expressed as tracked-element mass. Negative output means loss from water.
pub fn bubblingFluxesG(water_volume_m3: f64, minimum_water_volume_m3: f64, temperature_k: f64, dissolved_mass_g: []const f64, mass_solubility_ratio: []const f64, iteration_fraction: f64, output_flux_g: []f64) !void {
    if (dissolved_mass_g.len != species_count or mass_solubility_ratio.len != species_count or output_flux_g.len != species_count) return error.GasSpeciesCountMismatch;
    if (!std.math.isFinite(water_volume_m3) or water_volume_m3 < 0 or !std.math.isFinite(minimum_water_volume_m3) or minimum_water_volume_m3 < 0 or !std.math.isFinite(temperature_k) or temperature_k <= 0 or !std.math.isFinite(iteration_fraction) or iteration_fraction < 0 or iteration_fraction > 1) return error.InvalidGasBubblingInput;
    for (dissolved_mass_g, mass_solubility_ratio) |mass, solubility| {
        if (!std.math.isFinite(mass) or mass < 0 or !std.math.isFinite(solubility) or solubility <= 0) return error.InvalidGasBubblingInput;
    }
    return bubblingFluxesGFromValidatedInputs(water_volume_m3, minimum_water_volume_m3, temperature_k, dissolved_mass_g, mass_solubility_ratio, iteration_fraction, output_flux_g);
}

/// `ecosys_f77/trnsfr.f:5777-5778` wraps the whole `VTATM/VTGAS` bubbling block
/// in a minimum aqueous carrier test, and `5880-5889` is its explicit `ELSE`:
///
///     THETW1(N3,N2,N1)=AMAX1(0.0,VOLWM(M,N3,N2,N1)/VOLY(N3,N2,N1))
///     IF(THETW1(N3,N2,N1).GT.THETZ(N3,N2,N1).AND.IFLGB.EQ.0)THEN
///     ...  VTATM=AMAX1(0.0,1.2194E+04*VOLWM(M,N3,N2,N1)/TKSM(M,N3,N2,N1))
///     ELSE
///     RCOBBL(N3,N2,N1)=0.0   ! ... and the other seven
///
/// So the else-behaviour is exactly zero bubbling, not a vanishing capacity.
/// Without a floor the translated capacity `1.2194e4 * water / T` collapses to
/// zero as the carrier dries, every remaining dissolved gram reads as
/// supersaturated, and the layer's whole aqueous inventory degasses -- an
/// ongoing mass sink the source does not have.
///
/// `minimum_water_volume_m3` carries the area-scaled `ZEROS2` volumetric floor
/// (`starts.f:94,270`). That is a strict subset of the source's `THETZ` gate,
/// which is a much larger hygroscopic water *content*: this therefore never
/// suppresses bubbling the source performs. Translating `THETZ` itself needs
/// `VOLY` and the per-layer hygroscopic content, which this kernel does not
/// receive; that remains open.
///
/// Exactly zero water is deliberately excluded from the floor. It is not an
/// unresolvable carrier but the total absence of an aqueous phase, so any
/// dissolved inventory left there is a state inconsistency rather than a
/// solute; ecosys-ng resolves that degenerate case by evacuating the
/// inventory to the gaseous phase (the REDIST `LG` receiver, or the landscape
/// boundary when the column has none), and callers depend on it. The floor
/// governs only the range `(0, minimum]`, where a carrier does exist, the
/// source performs no bubbling, and expelling the whole inventory is a
/// standing, unbounded mass sink.
pub fn bubblingFluxesGFromValidatedInputs(water_volume_m3: f64, minimum_water_volume_m3: f64, temperature_k: f64, dissolved_mass_g: []const f64, mass_solubility_ratio: []const f64, iteration_fraction: f64, output_flux_g: []f64) !void {
    if (water_volume_m3 > 0 and water_volume_m3 <= minimum_water_volume_m3) {
        @memset(output_flux_g, 0);
        return;
    }
    var equivalent_gas_mol: f64 = 0;
    for (dissolved_mass_g, mass_solubility_ratio, g_per_mol_tracked) |mass, solubility, molar_mass| {
        equivalent_gas_mol += mass / (molar_mass * solubility);
    }
    const capacity_mol = @max(0, 1.2194e4 * water_volume_m3 / temperature_k);
    if (equivalent_gas_mol <= capacity_mol or equivalent_gas_mol == 0) {
        @memset(output_flux_g, 0);
        return;
    }
    const bubble_volume_mol = (capacity_mol - equivalent_gas_mol) * iteration_fraction;
    for (output_flux_g, dissolved_mass_g, mass_solubility_ratio, g_per_mol_tracked) |*flux, mass, solubility, molar_mass| {
        const equivalent_species_mol = mass / (molar_mass * solubility);
        flux.* = @max(-mass * iteration_fraction, @min(0, bubble_volume_mol * equivalent_species_mol / equivalent_gas_mol * molar_mass * solubility));
        if (!std.math.isFinite(flux.*)) return error.NonFiniteGasBubblingFlux;
    }
}

test "gas diffusion geometry and series boundary preserve source equations" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.4 * 0.7 * 0.4 / 0.5 * 2 / 0.1), try airFilledDiffusionGeometry(0.4, 0.7, 0.5, 2, 0.1), 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), try seriesConductance(2, 3), 1e-14);
}

test "validated gas transport kernels are bit-identical to checked entry points" {
    try std.testing.expectEqual(
        try seriesConductance(0.25, 0.75),
        seriesConductanceFromValidatedInputs(0.25, 0.75),
    );
    try std.testing.expectEqual(
        try atmosphericDiffusiveFluxG(2, 1.5, 0.75, 0.2, 0.125),
        atmosphericDiffusiveFluxGFromValidatedInputs(2, 1.5, 0.75, 0.2, 0.125),
    );
    try std.testing.expectEqual(
        try phaseExchangeFluxG(4, 6, 2, 3, 0.5, 0.4),
        try phaseExchangeFluxGFromValidatedInputs(4, 6, 2, 3, 0.5, 0.4),
    );

    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.air_volume_m3[0] = 1.25;
    state.air_volume_m3[1] = 0.75;
    state.temperature_k[0] = 298.15;
    state.temperature_k[1] = 301.25;
    state.water_vapor_mol[0] = 0.01;
    state.water_vapor_mol[1] = 0.02;
    for (0..species_count) |species| {
        state.gaseous_mass_g[species] = @as(f64, @floatFromInt(species + 1)) * 0.3;
        state.gaseous_mass_g[species_count + species] = @as(f64, @floatFromInt(species + 2)) * 0.2;
        state.dissolved_mass_g[species] = @as(f64, @floatFromInt(species + 1)) * 0.4;
    }
    const conductance = [_]f64{ 0.11, 0.13, 0.17, 0.19, 0.23, 0.29, 0.31 };
    const solubility = [_]f64{ 0.7, 0.08, 0.03, 0.02, 0.5, 200, 0.04 };
    var checked: [species_count]f64 = undefined;
    var validated: [species_count]f64 = undefined;
    const face: Face = .{ .first_cell = 0, .second_cell = 1 };
    try calculateFaceDiffusiveFluxesG(&state, face, &conductance, .{ 1e-9, 1e-9 }, &checked);
    try calculateFaceDiffusiveFluxesGFromValidatedInputs(&state, face, &conductance, .{ 1e-9, 1e-9 }, &validated);
    try std.testing.expectEqualSlices(f64, &checked, &validated);

    try pressureDrivenFluxesG(state.air_volume_m3[0], state.temperature_k[0], state.water_vapor_mol[0], state.gaseous_mass_g[0..species_count], 0.125, &checked);
    try pressureDrivenFluxesGFromValidatedInputs(state.air_volume_m3[0], state.temperature_k[0], state.water_vapor_mol[0], state.gaseous_mass_g[0..species_count], 0.125, &validated);
    try std.testing.expectEqualSlices(f64, &checked, &validated);

    try adjacentPressureDrivenFluxesG(state.gaseous_mass_g[0..species_count], state.gaseous_mass_g[species_count .. 2 * species_count], state.air_volume_m3[1], state.temperature_k[1], state.water_vapor_mol[1], 0.125, &checked);
    try adjacentPressureDrivenFluxesGFromValidatedInputs(state.gaseous_mass_g[0..species_count], state.gaseous_mass_g[species_count .. 2 * species_count], state.air_volume_m3[1], state.temperature_k[1], state.water_vapor_mol[1], 0.125, &validated);
    try std.testing.expectEqualSlices(f64, &checked, &validated);

    try bubblingFluxesG(0.001, 1e-6, state.temperature_k[0], state.dissolved_mass_g[0..species_count], &solubility, 0.125, &checked);
    try bubblingFluxesGFromValidatedInputs(0.001, 1e-6, state.temperature_k[0], state.dissolved_mass_g[0..species_count], &solubility, 0.125, &validated);
    try std.testing.expectEqualSlices(f64, &checked, &validated);
}

test "atmospheric and pressure gas fluxes are bounded" {
    const diffusion = try atmosphericDiffusiveFluxG(2, 1, 1, 10, 0.25);
    // A quarter step can move at most one quarter of the distance to
    // atmospheric equilibrium, even when conductance is otherwise unlimited.
    try std.testing.expectEqual(@as(f64, -0.25), diffusion);
    var flux: [species_count]f64 = undefined;
    try pressureDrivenFluxesG(0, 300, 0, &[_]f64{ 12, 0, 0, 0, 0, 0, 0 }, 0.25, &flux);
    try std.testing.expectEqual(@as(f64, -3), flux[0]);
}

test "phase exchange conserves gas plus dissolved inventory" {
    const flux = try phaseExchangeFluxG(4, 6, 2, 3, 0.5, 0.4);
    try std.testing.expectApproxEqAbs(@as(f64, -0.6857142857142857), flux, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 10), (4 + flux) + (6 - flux), 1e-14);
}

test "internal face diffusion conserves all seven gases" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.air_volume_m3[0] = 1;
    state.air_volume_m3[1] = 2;
    @memcpy(try state.gaseousMasses(0), &[_]f64{ 2, 3, 4, 5, 6, 7, 8 });
    var flux: [species_count]f64 = undefined;
    try calculateFaceDiffusiveFluxesG(&state, .{ .first_cell = 0, .second_cell = 1 }, &([_]f64{0.1} ** species_count), .{ 1e-9, 1e-9 }, &flux);
    try state_updateFaceFluxesG(&state, .{ .first_cell = 0, .second_cell = 1 }, &flux);
    const first = try state.gaseousMassesConst(0);
    const second = try state.gaseousMassesConst(1);
    for (first, second, [_]f64{ 2, 3, 4, 5, 6, 7, 8 }) |a, b, total| try std.testing.expectApproxEqAbs(total, a + b, 1e-14);
}

test "atmospheric diffusion scales once with represented gas timestep" {
    // TRNSFR 1006--1021 and 3268--3295: conductance and both inventory
    // extents carry XNPT/XNPG. Hold the evaluated state fixed to isolate that
    // source equation: four quarter-step requests must equal one full step.
    const whole = try atmosphericDiffusiveFluxG(2, 1, 4, 0.25, 1);
    const quarter = try atmosphericDiffusiveFluxG(2, 1, 4, 0.25, 0.25);
    try std.testing.expectEqual(whole, 4 * quarter);
    try std.testing.expectEqual(@as(f64, 0.5), whole);
}

test "atmospheric diffusion timestep scaling preserves exact donor and equilibrium bounds" {
    const donor_limited = try atmosphericDiffusiveFluxG(2, 1, 0, 100, 0.25);
    try std.testing.expectEqual(@as(f64, -0.5), donor_limited);
    const equilibrium_limited = try atmosphericDiffusiveFluxG(2, 1, 4, 100, 0.25);
    try std.testing.expectEqual(@as(f64, 0.5), equilibrium_limited);
    try std.testing.expectEqual(@as(f64, 0), try atmosphericDiffusiveFluxG(2, 1, 4, 100, 0));
}

test "gas face transfer rejects a sub-tolerance overdraw without clipping" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.gaseous_mass_g[0] = 1;
    state.gaseous_mass_g[species_count] = 2;
    var flux = [_]f64{0} ** species_count;
    flux[0] = 1.0 + 1.0e-15;
    try std.testing.expectError(
        error.InsufficientGasForTransport,
        state_updateFaceFluxesG(&state, .{ .first_cell = 0, .second_cell = 1 }, &flux),
    );
    try std.testing.expectEqual(@as(f64, 1), state.gaseous_mass_g[0]);
    try std.testing.expectEqual(@as(f64, 2), state.gaseous_mass_g[species_count]);
}

test "bubbling only removes supersaturated dissolved gas" {
    var flux: [species_count]f64 = undefined;
    const dissolved = [_]f64{ 12, 12, 32, 28, 28, 14, 2 };
    // A resolvable carrier well above the floor whose molar content greatly
    // exceeds `1.2194e4 * water / T` still evacuates proportionally.
    try bubblingFluxesG(1e-5, 1e-6, 300, &dissolved, &([_]f64{1} ** species_count), 0.25, &flux);
    var released_mol: f64 = 0;
    for (flux, dissolved, g_per_mol_tracked) |value, mass, molar_mass| {
        try std.testing.expect(value < 0);
        try std.testing.expect(value >= -0.25 * mass);
        released_mol -= value / molar_mass;
    }
    const capacity_mol = 1.2194e4 * 1e-5 / 300.0;
    var dissolved_mol: f64 = 0;
    for (dissolved, g_per_mol_tracked) |mass, molar_mass| dissolved_mol += mass / molar_mass;
    try std.testing.expectApproxEqRel(
        0.25 * (dissolved_mol - capacity_mol),
        released_mol,
        1e-12,
    );
}

// `trnsfr.f:5777-5778` evaluates bubbling only above a minimum aqueous
// carrier, and `5880-5889` zeroes all eight fluxes otherwise. The translated
// capacity is proportional to the carrier volume, so without that floor a
// dry-but-not-exactly-empty layer reports its entire dissolved inventory as
// supersaturated and expels it -- a standing mass sink for dissolved
// CO2/CH4/O2 that the source does not contain.
test "an unresolvable aqueous carrier bubbles nothing instead of degassing everything" {
    const dissolved = [_]f64{ 12, 12, 32, 28, 28, 14, 2 };
    const solubility = [_]f64{1} ** species_count;
    var floored: [species_count]f64 = undefined;
    try bubblingFluxesG(1.43e-35, 1e-6, 300, &dissolved, &solubility, 0.25, &floored);
    for (floored) |value| try std.testing.expectEqual(@as(f64, 0), value);

    // A total absence of aqueous phase is NOT the floored case: dissolved
    // mass there is a state inconsistency and is still evacuated, which
    // downstream callers rely on.
    var dry: [species_count]f64 = undefined;
    try bubblingFluxesG(0, 1e-6, 300, &dissolved, &solubility, 0.25, &dry);
    for (dry, dissolved) |value, mass|
        try std.testing.expectApproxEqAbs(-0.25 * mass, value, 1e-12);

    // Exactly the state the floor exists to reject: the pre-fix kernel is
    // reproduced by passing a zero floor, and it removes every gram.
    var unfloored: [species_count]f64 = undefined;
    try bubblingFluxesG(1.43e-35, 0, 300, &dissolved, &solubility, 0.25, &unfloored);
    var retained_g: f64 = 0;
    var expelled_g: f64 = 0;
    for (floored, unfloored, dissolved) |with_floor, without_floor, mass| {
        retained_g += mass + with_floor;
        expelled_g += -without_floor;
        try std.testing.expectApproxEqAbs(-0.25 * mass, without_floor, 1e-12);
    }
    // Conservation tightens by exactly the inventory no longer expelled.
    try std.testing.expectApproxEqAbs(@as(f64, 128), retained_g, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 32), expelled_g, 1e-12);
}

// The volumetric `ZEROS2` half of `trnsfr.f:5303-5306`. `face_assembly.zig`
// applies the dimensionless `THETX` half at face construction, but a layer
// thin enough (the production deck permits `minimum_layer_thickness_m=1e-9`)
// clears that test while holding an air volume orders of magnitude below
// `ZEROS2 = 1e-6 * DH * DV`.
test "face diffusion is absent below the gaseous ZEROS2 minimum" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.air_volume_m3[0] = 1.43e-35;
    state.air_volume_m3[1] = 0.4;
    @memcpy(try state.gaseousMasses(0), &[_]f64{ 2, 3, 4, 5, 6, 7, 8 });
    const face: Face = .{ .first_cell = 0, .second_cell = 1 };
    const conductance = [_]f64{0.1} ** species_count;
    var flux: [species_count]f64 = undefined;
    try calculateFaceDiffusiveFluxesG(&state, face, &conductance, .{ 1e-6, 1e-6 }, &flux);
    for (flux) |value| try std.testing.expectEqual(@as(f64, 0), value);

    // Without the floor the same face is donor-clipped to the entire source
    // inventory, because `mass / 1.43e-35` is an absurd concentration.
    try calculateFaceDiffusiveFluxesG(&state, face, &conductance, .{ 0, 0 }, &flux);
    for (flux, [_]f64{ 2, 3, 4, 5, 6, 7, 8 }) |value, mass|
        try std.testing.expectEqual(mass, value);
}

test "adjacent pressure displacement is conservative and donor bounded" {
    var flux: [species_count]f64 = undefined;
    try adjacentPressureDrivenFluxesG(&[_]f64{ 1, 0, 0, 0, 0, 0, 0 }, &[_]f64{ 12, 0, 0, 0, 0, 0, 0 }, 1, 300, 0, 1, &flux);
    try std.testing.expect(flux[0] <= 1);
    try std.testing.expect(flux[0] >= -12);
    for (flux) |value| try std.testing.expect(std.math.isFinite(value));
}

test "STARTE activity coefficients match every source PARAMETER slot" {
    // `starte.f:32--34`:
    //   ACO2X=0.14, ACH4X=0.14, AOXYX=0.31, AN2GX=0.23, AN2OX=0.23,
    //   ANH3X=0.07, AH2GX=0.14
    // Read slot by slot through `Species` rather than as a literal array so a
    // reordering of `Species` cannot silently re-pair the coefficients.
    const expected = [_]struct { Species, f64 }{
        .{ .carbon_dioxide, 0.14 },
        .{ .methane, 0.14 },
        .{ .oxygen, 0.31 },
        .{ .nitrogen, 0.23 },
        .{ .nitrous_oxide, 0.23 },
        .{ .ammonia, 0.07 },
        .{ .hydrogen, 0.14 },
    };
    try std.testing.expectEqual(species_count, expected.len);
    for (expected) |pair|
        try std.testing.expectEqual(pair[1], starte_activity_coefficient[@intFromEnum(pair[0])]);
}

test "STARTE hydrogen activity coefficient reaches dissolved H2 mass" {
    // The previous table gave hydrogen AN2OX=0.23 instead of AH2GX=0.14. That
    // is not a cosmetic table-hygiene issue: `starte.f:1432--1433` seeds
    // H2GS through the same `EXP(AH2GX*CSTR1)` divisor as the other gases, and
    // `initializeSoilLayerCell` suppresses aqueous mass only for ammonia and
    // for submerged oxygen. So the wrong coefficient was multiplied into
    // initial dissolved H2 on every saline profile, biasing the starting
    // aqueous H2 inventory by exp((0.23 - 0.14) * CSTR1). Freshwater runs hid
    // it because CSTR1 = 0 makes the divisor exactly one for any coefficient.
    const ionic_strength = 2.0;
    const hydrogen = @intFromEnum(Species.hydrogen);

    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try initializeSoilLayerCell(&state, 0, 0.15, 0.25, 0.1, 1.5, 279.65, test_atmosphere, test_solubility, ionic_strength, starte_activity_coefficient);

    const temperature_c = 279.65 - 273.15;
    const solubility = test_solubility.reference_water_to_air[hydrogen] *
        @exp(test_solubility.log_intercept[hydrogen] -
            test_solubility.temperature_coefficient_per_c[hydrogen] * temperature_c);
    const expected = test_atmosphere[hydrogen] * solubility /
        @exp(0.14 * ionic_strength) * 0.25;
    try std.testing.expectApproxEqRel(expected, state.dissolved_mass_g[hydrogen], 1e-14);

    // Non-vacuity in the direction that matters: the old N2O value must not
    // reproduce this mass, i.e. the guard actually separates 0.14 from 0.23.
    const wrong = test_atmosphere[hydrogen] * solubility /
        @exp(0.23 * ionic_strength) * 0.25;
    try std.testing.expect(@abs(wrong - expected) > 1e-6 * expected);
}

const std = @import("std");
const conservation_tolerance = @import("conservation_tolerance.zig");

/// Default physical conservation criterion: one part per billion of accepted
/// boundary activity in the audited interval. This is intentionally owned by
/// conservation configuration, not inherited from nonlinear convergence.
pub const default_mass_balance_relative_tolerance: f64 = 1.0e-9;
pub const MassBalanceAbsoluteTolerance = conservation_tolerance.AbsolutePerArea;

/// Unit-aware numerical floors for deciding whether represented physical
/// quantities are present. These are not nonlinear residual tolerances and are
/// not conservation acceptance criteria. Each limit is evaluated as
/// `absolute floor + relative * |representative scale|` in the named unit.
pub const PhysicalTolerance = struct {
    relative: f64 = 1.0e-12,
    volume_m3: f64 = 1.0e-14,
    water_volume_m3: f64 = 1.0e-14,
    water_depth_m: f64 = 1.0e-12,
    heat_megajoules: f64 = 1.0e-10,
    temperature_k: f64 = 1.0e-9,
    carbon_g: f64 = 1.0e-10,
    nitrogen_g: f64 = 1.0e-12,
    phosphorus_g: f64 = 1.0e-12,
    oxygen_g: f64 = 1.0e-12,
    amount_mol: f64 = 1.0e-14,
    length_m: f64 = 1.0e-12,
    area_m2: f64 = 1.0e-14,
    soil_mass_megagrams: f64 = 1.0e-12,
    dimensionless: f64 = 1.0e-12,

    pub fn validate(self: PhysicalTolerance) !void {
        inline for (std.meta.fields(PhysicalTolerance)) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value <= 0) return error.InvalidPhysicalTolerance;
        }
    }

    pub fn scaled(self: PhysicalTolerance, absolute_floor: f64, representative_scale: f64) f64 {
        return absolute_floor + self.relative * @abs(representative_scale);
    }

    pub fn waterVolume(self: PhysicalTolerance, representative_scale_m3: f64) f64 {
        return self.scaled(self.water_volume_m3, representative_scale_m3);
    }

    pub fn volume(self: PhysicalTolerance, representative_scale_m3: f64) f64 {
        return self.scaled(self.volume_m3, representative_scale_m3);
    }

    pub fn waterDepth(self: PhysicalTolerance, representative_scale_m: f64) f64 {
        return self.scaled(self.water_depth_m, representative_scale_m);
    }

    pub fn heat(self: PhysicalTolerance, representative_scale_megajoules: f64) f64 {
        return self.scaled(self.heat_megajoules, representative_scale_megajoules);
    }

    pub fn temperature(self: PhysicalTolerance, representative_scale_k: f64) f64 {
        return self.scaled(self.temperature_k, representative_scale_k);
    }

    pub fn carbon(self: PhysicalTolerance, representative_scale_g: f64) f64 {
        return self.scaled(self.carbon_g, representative_scale_g);
    }

    pub fn nitrogen(self: PhysicalTolerance, representative_scale_g: f64) f64 {
        return self.scaled(self.nitrogen_g, representative_scale_g);
    }

    pub fn phosphorus(self: PhysicalTolerance, representative_scale_g: f64) f64 {
        return self.scaled(self.phosphorus_g, representative_scale_g);
    }

    pub fn oxygen(self: PhysicalTolerance, representative_scale_g: f64) f64 {
        return self.scaled(self.oxygen_g, representative_scale_g);
    }

    pub fn amount(self: PhysicalTolerance, representative_scale_mol: f64) f64 {
        return self.scaled(self.amount_mol, representative_scale_mol);
    }

    pub fn length(self: PhysicalTolerance, representative_scale_m: f64) f64 {
        return self.scaled(self.length_m, representative_scale_m);
    }

    pub fn area(self: PhysicalTolerance, representative_scale_m2: f64) f64 {
        return self.scaled(self.area_m2, representative_scale_m2);
    }

    pub fn soilMass(self: PhysicalTolerance, representative_scale_megagrams: f64) f64 {
        return self.scaled(self.soil_mass_megagrams, representative_scale_megagrams);
    }

    pub fn fraction(self: PhysicalTolerance, representative_scale: f64) f64 {
        return self.scaled(self.dimensionless, representative_scale);
    }
};

/// Unit-aware nonlinear residual tolerances. The legacy scalar is retained as
/// an input scale only; it is converted once and must not be passed directly
/// to a residual measured in a physical unit.
pub const NonlinearTolerance = struct {
    relative: f64 = 1.0e-8,
    water_volume_m3: f64 = 1.0e-13,
    water_depth_m: f64 = 1.0e-11,
    heat_megajoules: f64 = 1.0e-10,
    heat_megajoules_per_m2: f64 = 1.0e-10,
    temperature_k: f64 = 1.0e-9,
    water_potential_megapascal: f64 = 1.0e-11,
    carbon_g: f64 = 1.0e-10,
    nitrogen_g: f64 = 1.0e-11,
    phosphorus_g: f64 = 1.0e-11,
    oxygen_g: f64 = 1.0e-11,
    /// Tracked-element grams for mineral/ionic solutes without a dedicated
    /// elemental field above.
    solute_g: f64 = 1.0e-11,
    amount_mol: f64 = 1.0e-13,
    /// Aqueous and solid reaction coordinates. Unlike `amount_mol`, these
    /// solver variables are intensive concentrations, not cell inventories.
    reaction_mol_per_m3: f64 = 1.0e-13,
    /// Soil/litter cation and surface-site reaction coordinates.
    reaction_mol_per_megagram: f64 = 1.0e-13,
    length_m: f64 = 1.0e-11,
    area_m2: f64 = 1.0e-13,
    soil_mass_megagrams: f64 = 1.0e-11,
    dimensionless: f64 = 1.0e-11,

    pub fn fromLegacy(relative: f64, absolute: f64) NonlinearTolerance {
        return .{
            .relative = relative,
            .water_volume_m3 = absolute * 1.0e-2,
            .water_depth_m = absolute,
            .heat_megajoules = absolute * 10.0,
            .heat_megajoules_per_m2 = absolute * 10.0,
            .temperature_k = absolute * 100.0,
            .water_potential_megapascal = absolute,
            .carbon_g = absolute * 10.0,
            .nitrogen_g = absolute,
            .phosphorus_g = absolute,
            .oxygen_g = absolute,
            .solute_g = absolute,
            .amount_mol = absolute * 1.0e-2,
            .reaction_mol_per_m3 = absolute * 1.0e-2,
            .reaction_mol_per_megagram = absolute * 1.0e-2,
            .length_m = absolute,
            .area_m2 = absolute * 1.0e-2,
            .soil_mass_megagrams = absolute,
            .dimensionless = absolute,
        };
    }

    pub fn validate(self: NonlinearTolerance) !void {
        inline for (std.meta.fields(NonlinearTolerance)) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value <= 0) return error.InvalidNonlinearTolerance;
        }
    }

    pub fn scaled(self: NonlinearTolerance, absolute_floor: f64, residual_scale: f64) f64 {
        return absolute_floor + self.relative * @abs(residual_scale);
    }
};

pub const SimulationConfig = struct {
    lon_count: usize,
    lat_count: usize,
    soil_layers: usize,
    plant_populations: usize,
    worker_threads: usize,
    tile_cells: usize,
    relative_tolerance: f64,
    absolute_tolerance: f64,
    nonlinear_tolerance: NonlinearTolerance = .{},
    /// Deprecated dimensionless migration value accepted from older runtime
    /// records. It is never applied as a universal physical-unit threshold;
    /// when no explicit conservation-relative value exists it only raises the
    /// relative conservation tolerance.
    mass_balance_tolerance: f64 = 0,
    mass_balance_absolute_tolerance: conservation_tolerance.AbsolutePerArea = .{},
    /// Dimensionless relative conservation tolerance, applied to accepted
    /// boundary activity since the last audit/reset. Separate from the
    /// nonlinear residual relative tolerance above.
    mass_balance_relative_tolerance: f64 = default_mass_balance_relative_tolerance,
    /// Magnitude below which a physical quantity is treated as absent (leaf
    /// area, plant mass, water volume, combustible carbon). Deprecated legacy
    /// parser value retained for source compatibility; production science must
    /// use `physical_tolerance` with the appropriate unit instead.
    negligible_quantity_threshold: f64,
    physical_tolerance: PhysicalTolerance = .{},
    max_nonlinear_iterations: u16,
    picard_relaxation: f64,

    pub const Dimensions = struct {
        lon_count: usize,
        lat_count: usize,
        soil_layers: usize,
        plant_populations: usize,
    };

    pub const Execution = struct {
        worker_threads: usize,
        tile_cells: usize,
    };

    pub const Numerics = struct {
        relative_tolerance: f64,
        absolute_tolerance: f64,
        nonlinear_tolerance: ?NonlinearTolerance = null,
        /// Legacy dimensionless migration value; see the top-level field.
        mass_balance_tolerance: ?f64 = null,
        mass_balance_absolute_tolerance: conservation_tolerance.AbsolutePerArea = .{},
        mass_balance_relative_tolerance: ?f64 = null,
        /// Defaults to `absolute_tolerance` so existing callers are unchanged.
        negligible_quantity_threshold: ?f64 = null,
        physical_tolerance: PhysicalTolerance = .{},
        max_nonlinear_iterations: u16,
        picard_relaxation: f64 = 0.5,
    };

    pub fn init(dimensions: Dimensions, execution: Execution, numerics: Numerics) !SimulationConfig {
        const result = SimulationConfig{
            .lon_count = dimensions.lon_count,
            .lat_count = dimensions.lat_count,
            .soil_layers = dimensions.soil_layers,
            .plant_populations = dimensions.plant_populations,
            .worker_threads = execution.worker_threads,
            .tile_cells = execution.tile_cells,
            .relative_tolerance = numerics.relative_tolerance,
            .absolute_tolerance = numerics.absolute_tolerance,
            .nonlinear_tolerance = numerics.nonlinear_tolerance orelse NonlinearTolerance.fromLegacy(numerics.relative_tolerance, numerics.absolute_tolerance),
            .mass_balance_tolerance = numerics.mass_balance_tolerance orelse 0,
            .mass_balance_absolute_tolerance = numerics.mass_balance_absolute_tolerance,
            .mass_balance_relative_tolerance = numerics.mass_balance_relative_tolerance orelse @max(default_mass_balance_relative_tolerance, numerics.mass_balance_tolerance orelse 0),
            .negligible_quantity_threshold = numerics.negligible_quantity_threshold orelse numerics.absolute_tolerance,
            .physical_tolerance = numerics.physical_tolerance,
            .max_nonlinear_iterations = numerics.max_nonlinear_iterations,
            .picard_relaxation = numerics.picard_relaxation,
        };
        try result.validate();
        return result;
    }

    pub fn validate(self: SimulationConfig) !void {
        if (self.lon_count == 0 or self.lat_count == 0) return error.EmptyGrid;
        if (self.soil_layers == 0) return error.NoSoilLayers;
        if (self.plant_populations == 0) return error.NoPlantSpecies;
        if (self.worker_threads == 0) return error.NoWorkerThreads;
        if (self.tile_cells == 0) return error.EmptyTile;
        if (!std.math.isFinite(self.relative_tolerance) or self.relative_tolerance <= 0) return error.InvalidRelativeTolerance;
        if (!std.math.isFinite(self.absolute_tolerance) or self.absolute_tolerance <= 0) return error.InvalidAbsoluteTolerance;
        try self.nonlinear_tolerance.validate();
        if (!std.math.isFinite(self.mass_balance_tolerance) or self.mass_balance_tolerance < 0) return error.InvalidMassBalanceTolerance;
        try self.mass_balance_absolute_tolerance.validate();
        if (!std.math.isFinite(self.mass_balance_relative_tolerance) or self.mass_balance_relative_tolerance <= 0) return error.InvalidMassBalanceRelativeTolerance;
        if (!std.math.isFinite(self.negligible_quantity_threshold) or self.negligible_quantity_threshold <= 0) return error.InvalidNegligibleQuantityThreshold;
        try self.physical_tolerance.validate();
        if (self.max_nonlinear_iterations == 0) return error.NoNonlinearIterations;
        if (!std.math.isFinite(self.picard_relaxation) or self.picard_relaxation <= 0 or self.picard_relaxation > 1) return error.InvalidPicardRelaxation;
        _ = try std.math.mul(usize, self.lon_count, self.lat_count);
        const cells = try std.math.mul(usize, self.lon_count, self.lat_count);
        const cell_species = try std.math.mul(usize, cells, self.plant_populations);
        _ = try std.math.mul(usize, cell_species, self.soil_layers);
    }
};

test "explicit runtime configuration is valid" {
    const config = try SimulationConfig.init(
        .{ .lon_count = 13, .lat_count = 7, .soil_layers = 23, .plant_populations = 11 },
        .{ .worker_threads = 3, .tile_cells = 97 },
        .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-11, .max_nonlinear_iterations = 40 },
    );
    try std.testing.expectEqual(default_mass_balance_relative_tolerance, config.mass_balance_relative_tolerance);
    try std.testing.expect(config.mass_balance_relative_tolerance != config.relative_tolerance);
}

test "conservation relative tolerance is validated independently" {
    try std.testing.expectError(
        error.InvalidMassBalanceRelativeTolerance,
        SimulationConfig.init(
            .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
            .{ .worker_threads = 1, .tile_cells = 1 },
            .{
                .relative_tolerance = 1e-4,
                .absolute_tolerance = 1e-8,
                .mass_balance_relative_tolerance = 0,
                .max_nonlinear_iterations = 2,
            },
        ),
    );
}

test "physical tolerances are unit distinct and scale independently of nonlinear convergence" {
    const config = try SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-5, .absolute_tolerance = 1e-8, .max_nonlinear_iterations = 2 },
    );
    const physical = config.physical_tolerance;
    try std.testing.expect(physical.water_volume_m3 != physical.heat_megajoules);
    try std.testing.expect(physical.temperature_k != 1e-8);
    try std.testing.expectEqual(physical.volume_m3 + physical.relative * 3.0, physical.volume(3.0));
    try std.testing.expectEqual(physical.water_volume_m3 + physical.relative * 2.0, physical.waterVolume(2.0));
    try std.testing.expectEqual(physical.carbon_g + physical.relative * 30.0, physical.carbon(-30.0));
}

test "legacy nonlinear scalar is converted into unit-aware floors" {
    const config = try SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 2e-7, .absolute_tolerance = 3e-11, .max_nonlinear_iterations = 2 },
    );
    try std.testing.expectEqual(@as(f64, 2e-7), config.nonlinear_tolerance.relative);
    try std.testing.expectEqual(@as(f64, 3e-13), config.nonlinear_tolerance.water_volume_m3);
    try std.testing.expectEqual(@as(f64, 3e-10), config.nonlinear_tolerance.heat_megajoules_per_m2);
    try std.testing.expectEqual(@as(f64, 3e-9), config.nonlinear_tolerance.temperature_k);
    try std.testing.expectEqual(@as(f64, 3e-11), config.nonlinear_tolerance.water_potential_megapascal);
    try std.testing.expectEqual(@as(f64, 3e-11), config.nonlinear_tolerance.solute_g);
    try std.testing.expect(config.nonlinear_tolerance.amount_mol != config.nonlinear_tolerance.carbon_g);
    try std.testing.expectEqual(@as(f64, 3e-13), config.nonlinear_tolerance.reaction_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 3e-13), config.nonlinear_tolerance.reaction_mol_per_megagram);
    try std.testing.expectEqual(
        config.nonlinear_tolerance.oxygen_g + 2e-7 * 4.0,
        config.nonlinear_tolerance.scaled(config.nonlinear_tolerance.oxygen_g, 4.0),
    );
}

test "invalid typed physical tolerance fails configuration validation" {
    try std.testing.expectError(
        error.InvalidPhysicalTolerance,
        SimulationConfig.init(
            .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
            .{ .worker_threads = 1, .tile_cells = 1 },
            .{
                .relative_tolerance = 1e-5,
                .absolute_tolerance = 1e-8,
                .physical_tolerance = .{ .oxygen_g = 0 },
                .max_nonlinear_iterations = 2,
            },
        ),
    );
}

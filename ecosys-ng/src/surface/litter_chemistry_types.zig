//! `litter_chemistry` declarations: types.
//!
//! Split out of `litter_chemistry.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const ledger = @import("litter_reaction_transformations.zig");
const activity_coefficients = @import("../soil/solute/activity_coefficients.zig");
const numerics = @import("../core/numerics.zig");
const group_activity = @import("litter_chemistry_activity.zig");
const group_phosphate_minerals = @import("litter_chemistry_phosphate_minerals.zig");
const group_struct_arithmetic = @import("litter_chemistry_struct_arithmetic.zig");

/// All litter chemistry storage is allocated by runtime horizontal cell count.
/// Field units are inherited from the explicit reaction ledger: aqueous and
/// solid values are mol/m3; exchange values are mol/Mg.
pub const Cell = ledger.Transformations;

pub const State = struct {
    allocator: std.mem.Allocator,
    cells: []Cell,
    /// Source `PH(0)` is an independent intensive litter state. Dynamic salt
    /// chemistry updates it from the starting water-equilibrium H activity;
    /// dry cells and fixed-pH chemistry retain it. It is deliberately not a
    /// reaction coordinate or a conserved hydrogen inventory.
    ph: []f64,
    /// Water volume represented by the stored solid-mineral concentrations.
    /// A dry cell retains its last positive reference so extensive solids
    /// remain representable without infinity.
    mineral_reference_water_m3: []f64,
    /// Zero while the aqueous carrier is wet. When a cell evaporates to exactly
    /// dry, this remembers the carrier its stored aqueous concentrations refer
    /// to, so the extensive amount survives and rewetting can rescale from it
    /// rather than from zero. See `surface_litter_chemistry_carrier_rebase` and
    /// EXEC-004. Kept separate from `mineral_reference_water_m3`, which tracks
    /// the solid-mineral basis and is written by other callers.
    dry_reference_water_m3: []f64,
    /// Hourly extensive surface `TBH2O` from the accepted fraction of the
    /// source-order starting-water RHHX transformation. This balance owner is
    /// distinct from the solvent-water concentration stored in each `Cell`.
    water_equilibrium_balance_mol: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroLitterChemistryCellCount;
        const cells = try allocator.alloc(Cell, cell_count);
        errdefer allocator.free(cells);
        const ph = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(ph);
        const mineral_reference_water_m3 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(mineral_reference_water_m3);
        const dry_reference_water_m3 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(dry_reference_water_m3);
        const water_equilibrium_balance_mol = try allocator.alloc(f64, cell_count);
        for (cells) |*cell| group_struct_arithmetic.zeroValue(Cell, cell);
        @memset(ph, std.math.nan(f64));
        @memset(mineral_reference_water_m3, 0);
        @memset(dry_reference_water_m3, 0);
        @memset(water_equilibrium_balance_mol, 0);
        return .{
            .allocator = allocator,
            .cells = cells,
            .ph = ph,
            .mineral_reference_water_m3 = mineral_reference_water_m3,
            .dry_reference_water_m3 = dry_reference_water_m3,
            .water_equilibrium_balance_mol = water_equilibrium_balance_mol,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.water_equilibrium_balance_mol);
        self.allocator.free(self.dry_reference_water_m3);
        self.allocator.free(self.mineral_reference_water_m3);
        self.allocator.free(self.ph);
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn resetWaterEquilibriumBalanceHourly(self: *State) void {
        @memset(self.water_equilibrium_balance_mol, 0);
    }

    pub fn publishAcceptedWaterEquilibriumBalance(
        self: *State,
        cell_index: usize,
        extent_mol_per_m3: f64,
        litter_water_m3: f64,
    ) !void {
        if (cell_index >= self.cells.len)
            return error.LitterChemistryCellIndexOutOfBounds;
        if (!std.math.isFinite(extent_mol_per_m3) or
            !std.math.isFinite(litter_water_m3) or litter_water_m3 < 0)
            return error.InvalidLitterWaterEquilibriumBalance;
        const contribution = extent_mol_per_m3 * litter_water_m3;
        const next = self.water_equilibrium_balance_mol[cell_index] + contribution;
        if (!std.math.isFinite(contribution) or !std.math.isFinite(next))
            return error.InvalidLitterWaterEquilibriumBalance;
        self.water_equilibrium_balance_mol[cell_index] = next;
    }

    pub fn bindMineralReferenceWater(self: *State, water_m3: []const f64) !void {
        if (water_m3.len != self.cells.len)
            return error.LitterMineralReferenceDimensionMismatch;
        for (water_m3) |water|
            if (!std.math.isFinite(water) or water < 0)
                return error.InvalidLitterMineralReferenceWater;
        @memcpy(self.mineral_reference_water_m3, water_m3);
    }

    /// Preserves each solid mineral's extensive mol inventory while the
    /// litter-water carrier changes.
    pub fn renormalizeMinerals(self: *State, cell_index: usize, water_m3: f64) !void {
        if (cell_index >= self.cells.len)
            return error.LitterChemistryCellIndexOutOfBounds;
        if (!std.math.isFinite(water_m3) or water_m3 < 0)
            return error.InvalidLitterMineralReferenceWater;
        const old_water_m3 = self.mineral_reference_water_m3[cell_index];
        if (!std.math.isFinite(old_water_m3) or old_water_m3 < 0)
            return error.InvalidLitterMineralReferenceWater;
        var cell = self.cells[cell_index];
        try group_activity.validateMinerals(cell);
        if (old_water_m3 == 0) {
            if (group_activity.hasMineralInventory(cell))
                return error.UnboundLitterMineralInventory;
            self.mineral_reference_water_m3[cell_index] = water_m3;
            return;
        }
        // A concentration is undefined when dry. Retain the last positive
        // concentration/reference pair as an exact extensive inventory.
        if (water_m3 == 0) return;
        const scale = old_water_m3 / water_m3;
        inline for (@typeInfo(@TypeOf(cell.phosphate_minerals)).@"struct".fields) |field|
            @field(cell.phosphate_minerals, field.name) *= scale;
        inline for (@typeInfo(@TypeOf(cell.salt_minerals)).@"struct".fields) |field|
            @field(cell.salt_minerals, field.name) *= scale;
        try group_activity.validateMinerals(cell);
        self.cells[cell_index] = cell;
        self.mineral_reference_water_m3[cell_index] = water_m3;
    }
};

pub const Environment = struct {
    litter_mass_per_water_volume_megagrams_per_m3: f64,
    dynamic_salts: bool,
};

pub const ProbeCounts = struct {
    iterations: u32 = 0,

    pub fn record(self: *ProbeCounts) void {
        self.iterations = std.math.add(u32, self.iterations, 1) catch std.math.maxInt(u32);
    }
};

pub const Options = struct {
    absolute_tolerance_mol_per_m3: f64 = 1e-11,
    absolute_tolerance_mol_per_megagram: f64 = 1e-11,
    relative_tolerance: f64 = 1e-8,
    picard_relaxation: f64 = 0.5,
    directional_probe_fraction: f64 = 0.5,
    minimum_newton_fraction: f64 = 0.05,
    maximum_newton_fraction: f64 = 1.0,
    /// Reaction-equilibrium ceiling `MRXN=60`; successful solves exit early.
    max_iterations: u16 = 60,
    /// Depth-one Anderson acceleration of the bounded Picard recovery step,
    /// mirroring `core/numerics.zig` and `soil/gas/vapor_solver.zig`. This
    /// solver's state is a struct of coupled reaction coordinates rather than
    /// a plain vector, so it cannot delegate to the shared scalar solver; the
    /// same recovery semantics are reproduced locally via the generic
    /// field-iteration helpers in `litter_chemistry_struct_arithmetic.zig`. An
    /// Anderson candidate is accepted only when it strictly improves the
    /// accepted current iterate. The bounded-Picard sample is private secant
    /// history, never an acceptance incumbent. Production validation rejects
    /// false.
    anderson_recovery: bool = true,
    /// Internal transaction wiring. `solveCell` owns both objects and rejects
    /// caller-supplied pointers so nested helpers cannot split the nonlinear
    /// iteration counter or hide probe work behind a second counter.
    shared_budget: ?*numerics.NonlinearBudget = null,
    probe_counts: ?*ProbeCounts = null,

    pub fn scaleMolPerM3(self: Options, value: f64) f64 {
        return self.absolute_tolerance_mol_per_m3 +
            self.relative_tolerance * @abs(value);
    }

    pub fn scaleMolPerMegagram(self: Options, value: f64) f64 {
        return self.absolute_tolerance_mol_per_megagram +
            self.relative_tolerance * @abs(value);
    }

    pub fn scaleForField(self: Options, comptime field_name: []const u8, value: f64) f64 {
        return if (comptime std.mem.endsWith(u8, field_name, "_per_megagram"))
            self.scaleMolPerMegagram(value)
        else
            self.scaleMolPerM3(value);
    }
};

pub fn probeCap(options: Options, existing_cap: u16) u16 {
    return @min(existing_cap, options.max_iterations);
}

pub fn recordProbe(options: Options) void {
    if (options.probe_counts) |counts| counts.record();
}

pub const Result = struct {
    iterations: u16,
    newton_raphson_steps: u16,
    picard_steps: u16,
    maximum_scaled_residual: f64,
    /// Recovery steps taken with the Anderson candidate rather than the plain
    /// bounded Picard candidate. Counted inside `picard_steps` as well, so the
    /// existing step accounting is unchanged.
    anderson_steps: u16 = 0,
    accepted_updates: u16 = 0,
    probe_iterations: u32 = 0,
    accepted_water_equilibrium_extent_mol_per_m3: f64 = 0,
};

pub const phosphate_coordinate_count: usize = 18;

/// Fixed-pH variscite and strengite targets are externally buffered in
/// SOLUTE, so precipitation can terminate at the dissolved Al/Fe bounds
/// instead of at both mutually incompatible saturation targets. Accelerate
/// those two bound-active reactions together from one pre-update evaluation,
/// conserving Al, Fe, and P exactly. The caller accepts only a reduction of
/// the complete reaction norm, so this cannot hide a competing mineral.
pub const fixed_phosphate_coordinate_count: usize = 6;

pub const fixed_phosphate_mineral_count: usize = 5;

pub const IncompatiblePhosphateSolid = enum { aluminum, iron };

pub const PhosphateReactionResidual = union(enum) {
    association,
    mineral: group_phosphate_minerals.PhosphateMineralReaction,
};

pub const reduced_active_coordinate_count: usize = 4;

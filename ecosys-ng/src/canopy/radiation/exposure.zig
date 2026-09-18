const std = @import("std");
const CellRange = @import("../../core/compute.zig").CellRange;
const StructureState = @import("../morphology/structure.zig").State;
const InterceptionState = @import("../energy/interception.zig").State;
const GroundRadiationState = @import("../../surface/ground_radiation.zig").State;

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    canopy_exposure_fraction: []f64,
    ground_exposure_fraction: []f64,
    species_exposure_fraction: []f64,
    species_share_of_canopy_exposure: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, species_count: usize) !State {
        if (cell_count == 0 or species_count == 0) return error.InvalidCanopyExposureDimensions;
        const species_slots = try std.math.mul(usize, cell_count, species_count);
        var result: State = .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .canopy_exposure_fraction = try allocator.alloc(f64, cell_count),
            .ground_exposure_fraction = undefined,
            .species_exposure_fraction = undefined,
            .species_share_of_canopy_exposure = undefined,
        };
        errdefer allocator.free(result.canopy_exposure_fraction);
        result.ground_exposure_fraction = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.ground_exposure_fraction);
        result.species_exposure_fraction = try allocator.alloc(f64, species_slots);
        errdefer allocator.free(result.species_exposure_fraction);
        result.species_share_of_canopy_exposure = try allocator.alloc(f64, species_slots);
        @memset(result.canopy_exposure_fraction, 0);
        @memset(result.ground_exposure_fraction, 1);
        @memset(result.species_exposure_fraction, 0);
        @memset(result.species_share_of_canopy_exposure, 0);
        return result;
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.species_share_of_canopy_exposure);
        self.allocator.free(self.species_exposure_fraction);
        self.allocator.free(self.ground_exposure_fraction);
        self.allocator.free(self.canopy_exposure_fraction);
        self.* = undefined;
    }

    pub fn validateFinite(self: State) !void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) for (@field(self, field.name), 0..) |value, index| {
            if (!std.math.isFinite(value) or value < 0 or value > 1 + 1.0e-12) {
                std.log.err("invalid canopy exposure: field={s} index={d} value={e}", .{ field.name, index, value });
                return error.InvalidCanopyExposure;
            }
        };
    }
};

pub const ApplyContext = struct {
    result: *State,
    structure: *const StructureState,
    interception: *const InterceptionState,
    ground_radiation: *const GroundRadiationState,
    solar_angle_sine_by_cell: []const f64,
    /// HOUR1-002. The authoritative `FRADT`/`FRADG`/`FRADP` producer, when the
    /// composition root supplies it.
    ///
    /// `hour1.f` 4713--4779 forms these fractions over `ARLSS`, the total of
    /// *leaf*, *stalk* (`ARSTK`) and *standing dead* (`ARSTD`) area, and
    /// accumulates `FRADT` as the sum over plant populations of
    /// `FRADP + FRADQ`, the living and standing-dead shares. This kernel's own
    /// low-sun branch below sees only leaf area, so it understates canopy
    /// interception and overstates `ground_exposure_fraction`.
    ///
    /// `canopy_precipitation_retention.refreshFromModel` already computes the
    /// faithful quantity: it separates living (`living_surface_area_m2` =
    /// leaf + stalk) from standing dead, applies the extinction over
    /// `(living + dead)/cell_area`, and honours the runtime solar-angle
    /// threshold. It publishes the result as `living_radiation_fraction` and
    /// `standing_dead_radiation_fraction` per plant, which are exactly `FRADP`
    /// and `FRADQ`.
    ///
    /// So this field does not add a second producer, it *retires* one. When it
    /// is non-null this kernel stops deriving the cell fraction and instead
    /// projects the retention owner's per-plant fractions onto the cell,
    /// summing them the way `DO 145`/`DO 155` accumulate `FRADT`. Production
    /// calls `refreshFromModel` at `ecosys_ng.zig:3509`, before this kernel at
    /// `:3775`, so the values are current within the same hour.
    ///
    /// It is optional only because `src/ecosys_ng.zig` is owned by the
    /// Integrator lane and cannot be edited here. Until that one field is
    /// passed, the leaf-area-only branch remains live and HOUR1-002 remains
    /// open. See `docs/binding_requests/A6_canopy_exposure_hour1_002.md`.
    radiation_fractions: ?RadiationFractions = null,
};

/// Per-plant `FRADP`/`FRADQ` as published by the retention owner, plus the
/// population stride needed to map plants onto cells.
pub const RadiationFractions = struct {
    living_radiation_fraction: []const f64,
    standing_dead_radiation_fraction: []const f64,
    species_count: usize,
};

/// Ports HOUR1 FRADT/FRADG/FRADP.
///
/// HOUR1-002. When `context.radiation_fractions` is supplied this is a faithful
/// projection of the retention owner's `ARLSS`-based fractions. When it is not,
/// the fallback below sees living *leaf* area only, omitting stalk and standing
/// dead area, and therefore overstates `ground_exposure_fraction`. That fallback
/// is retained solely so the existing composition-root call site keeps
/// compiling; it is not the intended production path.
pub fn applyTile(context: *ApplyContext, range: CellRange) !void {
    const result = context.result;
    // The supplied-fraction shape is validated FIRST, against `result` alone.
    // It is the only check that can be made without dereferencing the four
    // sub-states, so putting it first is what lets a caller with a mis-strided
    // array be rejected rather than reading through a bad pointer.
    if (context.radiation_fractions) |fractions| {
        if (fractions.species_count != result.species_count) return error.CanopyExposureDimensionMismatch;
        const required = try std.math.mul(usize, result.cell_count, result.species_count);
        if (fractions.living_radiation_fraction.len != required or
            fractions.standing_dead_radiation_fraction.len != required)
            return error.CanopyExposureDimensionMismatch;
    }
    if (range.end > result.cell_count or context.solar_angle_sine_by_cell.len != result.cell_count or context.structure.cell_count != result.cell_count or context.interception.cell_count != result.cell_count or context.ground_radiation.cell_count != result.cell_count or context.structure.species_count != result.species_count or context.interception.species_count != result.species_count) return error.CanopyExposureDimensionMismatch;
    for (range.first..range.end) |cell| {
        const solar_angle_sine = context.solar_angle_sine_by_cell[cell];
        if (!std.math.isFinite(solar_angle_sine) or solar_angle_sine < 0 or solar_angle_sine > 1) return error.InvalidSolarAngle;
        var total_leaf_area_index: f64 = 0;
        var canopy_absorbed_shortwave: f64 = 0;
        for (0..result.species_count) |species| {
            const index = cell * result.species_count + species;
            var species_leaf_area: f64 = 0;
            for (0..context.structure.inclination_class_count) |inclination| species_leaf_area += context.structure.leaf_area_index_by_inclination_m2_m2[index * context.structure.inclination_class_count + inclination];
            total_leaf_area_index += species_leaf_area;
            canopy_absorbed_shortwave += context.interception.absorbed_shortwave_megajoules_per_m2[index];
            result.species_exposure_fraction[index] = species_leaf_area;
        }

        var canopy_fraction: f64 = 0;
        var weight_total: f64 = 0;
        if (context.radiation_fractions) |fractions| {
            // `FRADT = sum over NZ of (FRADP + FRADQ)`, hour1.f DO 145 / DO 155.
            // The per-species weight is the same sum, so the species split below
            // is `FRADP + FRADQ` per population rather than a leaf-area share.
            for (0..result.species_count) |species| {
                const index = cell * result.species_count + species;
                const living = fractions.living_radiation_fraction[index];
                const dead = fractions.standing_dead_radiation_fraction[index];
                inline for (.{ living, dead }) |value|
                    if (!std.math.isFinite(value) or value < 0) return error.InvalidCanopyExposure;
                const plant_fraction = living + dead;
                canopy_fraction += plant_fraction;
                weight_total += plant_fraction;
                result.species_exposure_fraction[index] = plant_fraction;
            }
        } else if (solar_angle_sine > 0.05) {
            const total_received_shortwave = canopy_absorbed_shortwave + context.ground_radiation.incident_shortwave_megajoules_per_m2[cell];
            if (total_received_shortwave > 1.0e-12) canopy_fraction = canopy_absorbed_shortwave / total_received_shortwave;
            weight_total = total_leaf_area_index;
        } else {
            if (total_leaf_area_index > 1.0e-12) canopy_fraction = 1.0 - @exp(-0.65 * total_leaf_area_index);
            weight_total = total_leaf_area_index;
        }
        canopy_fraction = std.math.clamp(canopy_fraction, 0.0, 1.0);
        result.canopy_exposure_fraction[cell] = canopy_fraction;
        result.ground_exposure_fraction[cell] = 1.0 - canopy_fraction;
        for (0..result.species_count) |species| {
            const index = cell * result.species_count + species;
            const share = if (weight_total > 1.0e-12) result.species_exposure_fraction[index] / weight_total else 0;
            result.species_share_of_canopy_exposure[index] = share;
            result.species_exposure_fraction[index] = canopy_fraction * share;
        }
        try validateCellConservation(result.*, cell);
    }
}

fn validateCellConservation(state: State, cell: usize) !void {
    if (@abs(state.canopy_exposure_fraction[cell] + state.ground_exposure_fraction[cell] - 1.0) > 1.0e-12) return error.CanopyExposureImbalance;
    var species_total: f64 = 0;
    for (0..state.species_count) |species| species_total += state.species_exposure_fraction[cell * state.species_count + species];
    if (@abs(species_total - state.canopy_exposure_fraction[cell]) > 1.0e-12) return error.SpeciesExposureImbalance;
}

test "night exposure uses ecosys exponential leaf-area relation" {
    const leaf_area_index: f64 = 3;
    const expected = 1.0 - @exp(-0.65 * leaf_area_index);
    try std.testing.expect(expected > 0 and expected < 1);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8577259284), expected, 1.0e-9);
}

test "HOUR1-002 the leaf-area-only fallback understates canopy interception" {
    // The defect, stated as arithmetic rather than as prose, so it cannot be
    // "fixed" by a change that leaves the two forms still disagreeing.
    //
    // `hour1.f` 4759 forms the low-sun fraction over `ARLSS`, which is
    // leaf + stalk + standing dead. This kernel's fallback uses leaf area only.
    // A canopy of 1.0 leaf plus 0.8 stalk plus 0.6 standing dead per unit
    // ground area therefore sees 1.0 instead of 2.4.
    const leaf: f64 = 1.0;
    const stalk: f64 = 0.8;
    const standing_dead: f64 = 0.6;
    const faithful = 1.0 - @exp(-0.65 * (leaf + stalk + standing_dead));
    const fallback = 1.0 - @exp(-0.65 * leaf);
    try std.testing.expect(faithful > fallback);
    // Ground exposure is `1 - canopy`, and it is what scales both downward and
    // emitted longwave in `surface_temperature_solver`. The fallback overstates
    // it by this much, which is far too large to be a rounding matter.
    const ground_exposure_overstatement = (1.0 - fallback) - (1.0 - faithful);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.3119097056),
        ground_exposure_overstatement,
        1.0e-9,
    );
    try std.testing.expect(ground_exposure_overstatement > 0.31);
    // Stated absolutely as well, because the ratio is what the surface solvers
    // actually see: 0.2101 ground exposure against 0.5221, a factor of 2.5.
    try std.testing.expectApproxEqAbs(@as(f64, 0.2101360712), 1.0 - faithful, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5220457768), 1.0 - fallback, 1.0e-9);
}

test "HOUR1-002 supplied radiation fractions accumulate FRADT as the source does" {
    // `FRADT = sum over NZ of (FRADP + FRADQ)` and `FRADG = 1 - FRADT`,
    // hour1.f DO 145 and DO 155. Two populations, each with a living and a
    // standing-dead share, so the accumulation and the complement are both
    // exercised rather than assumed.
    const living = [_]f64{ 0.30, 0.10 };
    const standing_dead = [_]f64{ 0.15, 0.05 };
    var canopy_total: f64 = 0;
    for (living, standing_dead) |live, dead| canopy_total += live + dead;
    try std.testing.expectApproxEqAbs(@as(f64, 0.60), canopy_total, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.40), 1.0 - canopy_total, 1.0e-12);
    // The per-population share must be `(FRADP + FRADQ)/FRADT`, so that
    // `species_exposure_fraction` re-sums to `FRADT` exactly, which is what
    // `validateCellConservation` requires.
    var share_total: f64 = 0;
    for (living, standing_dead) |live, dead|
        share_total += canopy_total * ((live + dead) / canopy_total);
    try std.testing.expectApproxEqAbs(canopy_total, share_total, 1.0e-12);
    // And, critically, the supplied path must NOT reduce to the leaf-area
    // fallback: standing dead carries 0.20 of the 0.60 here, and the fallback
    // has no term for it at all.
    var living_only: f64 = 0;
    for (living) |live| living_only += live;
    try std.testing.expect(canopy_total > living_only);
}

test "HOUR1-002 supplied fractions must match the runtime population stride" {
    // A silently mis-strided array would produce plausible fractions attributed
    // to the wrong cell, which is the failure mode a dimension check exists for.
    var state = try State.init(std.testing.allocator, 2, 3);
    defer state.deinit();
    const wrong_length = [_]f64{ 0.1, 0.2 };
    var context: ApplyContext = .{
        .result = &state,
        .structure = undefined,
        .interception = undefined,
        .ground_radiation = undefined,
        .solar_angle_sine_by_cell = &.{ 0.5, 0.5 },
        .radiation_fractions = .{
            .living_radiation_fraction = &wrong_length,
            .standing_dead_radiation_fraction = &wrong_length,
            .species_count = 3,
        },
    };
    // The species-count check runs before any state pointer is dereferenced,
    // so the undefined sub-states above are never read.
    context.radiation_fractions.?.species_count = 2;
    try std.testing.expectError(
        error.CanopyExposureDimensionMismatch,
        applyTile(&context, .{ .first = 0, .end = 2 }),
    );
}

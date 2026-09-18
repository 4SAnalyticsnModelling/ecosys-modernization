// **A8a DISPOSITION: superseded by the bound runtime owner.**
// `snow_drift_routing.produceAndRoute` translates WATSUB 3877--4100, moves all
// live phases, heat, non-salt species and 41 dynamic-salt coordinates, and
// stages both cell and landscape boundary ledgers atomically. Production calls
// it from `hourly_heat_water_solute.advanceSnowDrift` on every accepted recovery
// substep. This scalar REDIST 870--891 kernel remains a reference test owner and
// must not be called in addition to the consolidated transaction.
//
// The legacy per-cell `CXR` versus `CXS` discrepancy documented in this file is
// resolved structurally: the runtime producer books the exact transported
// composition, so it never reuses the runoff variables.

const std = @import("std");

pub const SaltEquilibriumMode = enum {
    static,
    dynamic,
};

pub const ExternalBoundaryWindow = struct {
    first_column: usize,
    last_column_inclusive: usize,
    first_row: usize,
    last_row_inclusive: usize,
};

/// REDIST evaluates physical snow-drift faces in this order.
pub const Face = enum(u8) {
    east,
    west,
    south,
    north,

    pub const count: usize = @typeInfo(Face).@"enum".fields.len;
};

pub const PhaseFlux = struct {
    snow_m3_per_step: f64 = 0,
    liquid_water_m3_per_step: f64 = 0,
    ice_m3_per_step: f64 = 0,
    heat_megajoules_per_step: f64 = 0,
};

pub const ElementFlux = struct {
    carbon_dioxide_g_c_per_step: f64 = 0,
    methane_g_c_per_step: f64 = 0,
    ammonium_g_n_per_step: f64 = 0,
    ammonia_g_n_per_step: f64 = 0,
    nitrate_g_n_per_step: f64 = 0,
    nitrous_oxide_g_n_per_step: f64 = 0,
    dinitrogen_g_n_per_step: f64 = 0,
    h2po4_g_p_per_step: f64 = 0,
    hpo4_g_p_per_step: f64 = 0,
    oxygen_g_o_per_step: f64 = 0,
};

pub const MultiplicityOneSaltFlux = struct {
    aluminum_mol_per_step: f64 = 0,
    iron_mol_per_step: f64 = 0,
    hydrogen_mol_per_step: f64 = 0,
    calcium_mol_per_step: f64 = 0,
    magnesium_mol_per_step: f64 = 0,
    sodium_mol_per_step: f64 = 0,
    potassium_mol_per_step: f64 = 0,
    hydroxide_mol_per_step: f64 = 0,
    sulfate_mol_per_step: f64 = 0,
    chloride_mol_per_step: f64 = 0,
    carbonate_mol_per_step: f64 = 0,
    po4_mol_p_per_step: f64 = 0,
};

pub const MultiplicityTwoSaltFlux = struct {
    bicarbonate_mol_per_step: f64 = 0,
    aluminum_hydroxide_1_mol_per_step: f64 = 0,
    aluminum_sulfate_mol_per_step: f64 = 0,
    iron_hydroxide_1_mol_per_step: f64 = 0,
    iron_sulfate_mol_per_step: f64 = 0,
    calcium_hydroxide_mol_per_step: f64 = 0,
    calcium_carbonate_mol_per_step: f64 = 0,
    calcium_sulfate_mol_per_step: f64 = 0,
    magnesium_hydroxide_mol_per_step: f64 = 0,
    magnesium_carbonate_mol_per_step: f64 = 0,
    magnesium_sulfate_mol_per_step: f64 = 0,
    sodium_carbonate_mol_per_step: f64 = 0,
    sodium_sulfate_mol_per_step: f64 = 0,
    potassium_sulfate_mol_per_step: f64 = 0,
    calcium_po4_mol_p_per_step: f64 = 0,
};

pub const MultiplicityThreeSaltFlux = struct {
    aluminum_hydroxide_2_mol_per_step: f64 = 0,
    iron_hydroxide_2_mol_per_step: f64 = 0,
    calcium_bicarbonate_mol_per_step: f64 = 0,
    magnesium_bicarbonate_mol_per_step: f64 = 0,
    iron_hpo4_mol_p_per_step: f64 = 0,
    calcium_hpo4_mol_p_per_step: f64 = 0,
    magnesium_hpo4_mol_p_per_step: f64 = 0,
};

pub const MultiplicityFourSaltFlux = struct {
    aluminum_hydroxide_3_mol_per_step: f64 = 0,
    iron_hydroxide_3_mol_per_step: f64 = 0,
    phosphoric_acid_mol_p_per_step: f64 = 0,
    iron_h2po4_mol_p_per_step: f64 = 0,
    calcium_h2po4_mol_p_per_step: f64 = 0,
};

pub const MultiplicityFiveSaltFlux = struct {
    aluminum_hydroxide_4_mol_per_step: f64 = 0,
    iron_hydroxide_4_mol_per_step: f64 = 0,
};

pub const BoundaryFlux = struct {
    phases: PhaseFlux = .{},
    elements: ElementFlux = .{},
    multiplicity_one: MultiplicityOneSaltFlux = .{},
    multiplicity_two: MultiplicityTwoSaltFlux = .{},
    multiplicity_three: MultiplicityThreeSaltFlux = .{},
    multiplicity_four: MultiplicityFourSaltFlux = .{},
    multiplicity_five: MultiplicityFiveSaltFlux = .{},
};

pub const CumulativeOutwardLedger = struct {
    water_equivalent_m3: f64 = 0,
    heat_megajoules: f64 = 0,
    carbon_g_c: f64 = 0,
    nitrogen_g_n: f64 = 0,
    phosphorus_g_p: f64 = 0,
    oxygen_g_o: f64 = 0,
    ion_components_mol: f64 = 0,
};

pub const CellOutwardLedger = struct {
    water_equivalent_m3: f64 = 0,
    dissolved_inorganic_carbon_g_c: f64 = 0,
    dissolved_inorganic_nitrogen_g_n: f64 = 0,
    dissolved_inorganic_phosphorus_g_p: f64 = 0,
    ion_components_mol: f64 = 0,
};

pub const Inputs = struct {
    lon_count: usize,
    lat_count: usize,
    external_boundary_window: ExternalBoundaryWindow,
    flux_by_face: [Face.count][]const BoundaryFlux,
    negligible_water_m3_by_cell: []const f64,
    ice_water_equivalent_ratio: f64,
    phosphorus_g_p_per_mol_p: f64,
    salt_equilibrium_mode: SaltEquilibriumMode,
};

pub const State = struct {
    cumulative: CumulativeOutwardLedger,
    outward_by_cell: []CellOutwardLedger,
};

/// Accounts for snow-drift water, heat, elements, and dynamic salt solutes.
///
/// Traceability: REDIST.F lines 870--944 (`WQRS`, `HQRS`, `CXS`, `ZXS`,
/// `ZGS`, `PXS`, `OXS`, `PSS`, `SS1`--`SS4`, and `SSQ`). The source order
/// and strict water-equivalent threshold are retained. WATSUB only produces
/// horizontal snow-drift records, so this kernel evaluates each physical face
/// once for each physical horizontal face, matching the enclosing REDIST
/// horizontal-face gate after its layer loop is closed.
///
/// redist.f lines 887--889 update per-cell snow exports with retained runoff
/// locals `CXR`, `ZXR`, `ZGR`, and `PXR`. Using the immediately preceding
/// snow terms prevents stale or uninitialized cross-branch state and is an
/// intentional legacy-defect correction. The later snow salt accounting counts
/// this species as an ion component, not a second phosphorus mass.
pub fn apply(inputs: Inputs, state: *State) !void {
    const cell_count = try validateDimensions(inputs, state.*);
    try validateInputsAndState(inputs, state.*, cell_count);
    try preflightUpdates(inputs, state.*);

    const window = inputs.external_boundary_window;
    for (window.first_column..window.last_column_inclusive + 1) |column| {
        for (window.first_row..window.last_row_inclusive + 1) |row| {
            const cell = row * inputs.lon_count + column;
            for (std.meta.tags(Face)) |face| {
                if (!isExternalFace(face, column, row, window)) continue;
                const flux = inputs.flux_by_face[@intFromEnum(face)][cell];
                const direction = inwardSign(face);
                const water_equivalent_m3 = calculateSignedWaterEquivalent(
                    flux.phases,
                    direction,
                    inputs.ice_water_equivalent_ratio,
                ) catch unreachable;
                if (@abs(water_equivalent_m3) <=
                    inputs.negligible_water_m3_by_cell[cell]) continue;
                const transfer = calculateTransfer(
                    flux,
                    direction,
                    water_equivalent_m3,
                    inputs,
                ) catch unreachable;
                state.cumulative =
                    advanceCumulative(state.cumulative, transfer) catch unreachable;
                state.outward_by_cell[cell] =
                    advanceCell(state.outward_by_cell[cell], transfer) catch unreachable;
            }
        }
    }
}

const SignedTransfer = struct {
    water_equivalent_m3: f64,
    heat_megajoules: f64,
    inorganic_carbon_g_c: f64,
    mineral_nitrogen_g_n: f64,
    gaseous_nitrogen_g_n: f64,
    inorganic_phosphorus_g_p: f64,
    oxygen_g_o: f64,
    salt_phosphorus_g_p: f64,
    ion_components_mol: f64,
};

fn calculateTransfer(
    flux: BoundaryFlux,
    direction: f64,
    water_equivalent_m3: f64,
    inputs: Inputs,
) !SignedTransfer {
    const phases = flux.phases;
    const elements = flux.elements;
    var transfer: SignedTransfer = .{
        .water_equivalent_m3 = water_equivalent_m3,
        .heat_megajoules = try checkedProduct(direction, phases.heat_megajoules_per_step),
        .inorganic_carbon_g_c = try signedSourceSum(direction, &.{
            elements.carbon_dioxide_g_c_per_step,
            elements.methane_g_c_per_step,
        }),
        .mineral_nitrogen_g_n = try signedSourceSum(direction, &.{
            elements.ammonium_g_n_per_step,
            elements.ammonia_g_n_per_step,
            elements.nitrate_g_n_per_step,
        }),
        .gaseous_nitrogen_g_n = try signedSourceSum(direction, &.{
            elements.nitrous_oxide_g_n_per_step,
            elements.dinitrogen_g_n_per_step,
        }),
        .inorganic_phosphorus_g_p = try signedSourceSum(direction, &.{
            elements.h2po4_g_p_per_step,
            elements.hpo4_g_p_per_step,
        }),
        .oxygen_g_o = try checkedProduct(
            direction,
            elements.oxygen_g_o_per_step,
        ),
        .salt_phosphorus_g_p = 0,
        .ion_components_mol = 0,
    };
    if (inputs.salt_equilibrium_mode == .dynamic)
        try calculateDynamicSalts(flux, direction, inputs, &transfer);
    return transfer;
}

fn calculateSignedWaterEquivalent(
    phases: PhaseFlux,
    direction: f64,
    ice_water_equivalent_ratio: f64,
) !f64 {
    var phase_volume_m3 = try checkedSum(
        phases.snow_m3_per_step,
        phases.liquid_water_m3_per_step,
    );
    phase_volume_m3 = try checkedSum(
        phase_volume_m3,
        try checkedProduct(
            phases.ice_m3_per_step,
            ice_water_equivalent_ratio,
        ),
    );
    return checkedProduct(direction, phase_volume_m3);
}

fn calculateDynamicSalts(
    flux: BoundaryFlux,
    direction: f64,
    inputs: Inputs,
    transfer: *SignedTransfer,
) !void {
    const phosphorus_mol_p = try sourceSum(&.{
        flux.multiplicity_two.calcium_po4_mol_p_per_step,
        flux.multiplicity_three.iron_hpo4_mol_p_per_step,
        flux.multiplicity_three.calcium_hpo4_mol_p_per_step,
        flux.multiplicity_three.magnesium_hpo4_mol_p_per_step,
        flux.multiplicity_four.phosphoric_acid_mol_p_per_step,
        flux.multiplicity_four.iron_h2po4_mol_p_per_step,
        flux.multiplicity_four.calcium_h2po4_mol_p_per_step,
    });
    transfer.salt_phosphorus_g_p = try checkedProduct(
        try checkedProduct(direction, inputs.phosphorus_g_p_per_mol_p),
        phosphorus_mol_p,
    );

    const group_one = try checkedProduct(
        direction,
        try sourceStructSum(flux.multiplicity_one),
    );
    const group_two = try checkedProduct(
        try checkedProduct(direction, 2),
        try sourceStructSum(flux.multiplicity_two),
    );
    const group_three = try checkedProduct(
        try checkedProduct(direction, 3),
        try sourceStructSum(flux.multiplicity_three),
    );
    var group_four = try checkedProduct(
        try checkedProduct(direction, 4),
        try sourceStructSum(flux.multiplicity_four),
    );
    group_four = try checkedSum(
        group_four,
        try checkedProduct(
            try checkedProduct(direction, 5),
            try sourceStructSum(flux.multiplicity_five),
        ),
    );
    var ion_components_mol = try checkedSum(group_one, group_two);
    ion_components_mol = try checkedSum(ion_components_mol, group_three);
    transfer.ion_components_mol =
        try checkedSum(ion_components_mol, group_four);
}

fn advanceCumulative(
    current: CumulativeOutwardLedger,
    transfer: SignedTransfer,
) !CumulativeOutwardLedger {
    var next = current;
    next.water_equivalent_m3 =
        try checkedSum(next.water_equivalent_m3, -transfer.water_equivalent_m3);
    next.heat_megajoules = try checkedSum(next.heat_megajoules, -transfer.heat_megajoules);
    next.carbon_g_c =
        try checkedSum(next.carbon_g_c, -transfer.inorganic_carbon_g_c);
    next.nitrogen_g_n =
        try checkedSum(next.nitrogen_g_n, -transfer.mineral_nitrogen_g_n);
    next.nitrogen_g_n =
        try checkedSum(next.nitrogen_g_n, -transfer.gaseous_nitrogen_g_n);
    next.phosphorus_g_p =
        try checkedSum(next.phosphorus_g_p, -transfer.inorganic_phosphorus_g_p);
    next.phosphorus_g_p =
        try checkedSum(next.phosphorus_g_p, -transfer.salt_phosphorus_g_p);
    next.oxygen_g_o =
        try checkedSum(next.oxygen_g_o, -transfer.oxygen_g_o);
    next.ion_components_mol =
        try checkedSum(next.ion_components_mol, -transfer.ion_components_mol);
    return next;
}

fn advanceCell(
    current: CellOutwardLedger,
    transfer: SignedTransfer,
) !CellOutwardLedger {
    var next = current;
    next.water_equivalent_m3 =
        try checkedSum(next.water_equivalent_m3, -transfer.water_equivalent_m3);
    next.dissolved_inorganic_carbon_g_c = try checkedSum(
        next.dissolved_inorganic_carbon_g_c,
        -transfer.inorganic_carbon_g_c,
    );
    next.dissolved_inorganic_nitrogen_g_n = try checkedSum(
        next.dissolved_inorganic_nitrogen_g_n,
        -transfer.mineral_nitrogen_g_n,
    );
    next.dissolved_inorganic_nitrogen_g_n = try checkedSum(
        next.dissolved_inorganic_nitrogen_g_n,
        -transfer.gaseous_nitrogen_g_n,
    );
    next.dissolved_inorganic_phosphorus_g_p = try checkedSum(
        next.dissolved_inorganic_phosphorus_g_p,
        -transfer.inorganic_phosphorus_g_p,
    );
    next.ion_components_mol = try checkedSum(
        next.ion_components_mol,
        -transfer.ion_components_mol,
    );
    return next;
}

fn preflightUpdates(inputs: Inputs, state: State) !void {
    var cumulative = state.cumulative;
    const window = inputs.external_boundary_window;
    for (window.first_column..window.last_column_inclusive + 1) |column| {
        for (window.first_row..window.last_row_inclusive + 1) |row| {
            const cell = row * inputs.lon_count + column;
            var cell_ledger = state.outward_by_cell[cell];
            for (std.meta.tags(Face)) |face| {
                if (!isExternalFace(face, column, row, window)) continue;
                const flux = inputs.flux_by_face[@intFromEnum(face)][cell];
                const direction = inwardSign(face);
                const water_equivalent_m3 = try calculateSignedWaterEquivalent(
                    flux.phases,
                    direction,
                    inputs.ice_water_equivalent_ratio,
                );
                if (@abs(water_equivalent_m3) <=
                    inputs.negligible_water_m3_by_cell[cell]) continue;
                const transfer = try calculateTransfer(
                    flux,
                    direction,
                    water_equivalent_m3,
                    inputs,
                );
                cumulative = try advanceCumulative(cumulative, transfer);
                cell_ledger = try advanceCell(cell_ledger, transfer);
            }
        }
    }
}

fn validateDimensions(inputs: Inputs, state: State) !usize {
    if (inputs.lon_count == 0 or inputs.lat_count == 0)
        return error.InvalidSnowBoundaryDimensions;
    const cell_count = std.math.mul(
        usize,
        inputs.lon_count,
        inputs.lat_count,
    ) catch return error.InvalidSnowBoundaryDimensions;
    inline for (inputs.flux_by_face) |values|
        if (values.len != cell_count)
            return error.InvalidSnowBoundaryDimensions;
    if (inputs.negligible_water_m3_by_cell.len != cell_count or
        state.outward_by_cell.len != cell_count)
        return error.InvalidSnowBoundaryDimensions;
    const window = inputs.external_boundary_window;
    if (window.first_column > window.last_column_inclusive or
        window.first_row > window.last_row_inclusive or
        window.last_column_inclusive >= inputs.lon_count or
        window.last_row_inclusive >= inputs.lat_count)
        return error.InvalidSnowBoundaryWindow;
    return cell_count;
}

fn validateInputsAndState(inputs: Inputs, state: State, cell_count: usize) !void {
    if (!positiveFinite(inputs.ice_water_equivalent_ratio) or
        inputs.ice_water_equivalent_ratio > 1 or
        !positiveFinite(inputs.phosphorus_g_p_per_mol_p))
        return error.InvalidSnowBoundaryInput;
    inline for (inputs.flux_by_face) |values| {
        for (values) |flux| {
            try validateFiniteStruct(flux.phases);
            try validateFiniteStruct(flux.elements);
            try validateFiniteStruct(flux.multiplicity_one);
            try validateFiniteStruct(flux.multiplicity_two);
            try validateFiniteStruct(flux.multiplicity_three);
            try validateFiniteStruct(flux.multiplicity_four);
            try validateFiniteStruct(flux.multiplicity_five);
        }
    }
    for (0..cell_count) |cell| {
        if (!nonnegativeFinite(inputs.negligible_water_m3_by_cell[cell]))
            return error.InvalidSnowBoundaryInput;
        validateFiniteStruct(state.outward_by_cell[cell]) catch
            return error.InvalidSnowBoundaryState;
    }
    validateFiniteStruct(state.cumulative) catch
        return error.InvalidSnowBoundaryState;
}

fn isExternalFace(
    face: Face,
    column: usize,
    row: usize,
    window: ExternalBoundaryWindow,
) bool {
    return switch (face) {
        .east => column == window.last_column_inclusive,
        .west => column == window.first_column,
        .south => row == window.last_row_inclusive,
        .north => row == window.first_row,
    };
}

fn inwardSign(face: Face) f64 {
    return switch (face) {
        .east, .south => -1,
        .west, .north => 1,
    };
}

fn signedSourceSum(direction: f64, values: []const f64) !f64 {
    return checkedProduct(direction, try sourceSum(values));
}

fn sourceStructSum(value: anytype) !f64 {
    var total: f64 = 0;
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field|
        total = try checkedSum(total, @field(value, field.name));
    return total;
}

fn sourceSum(values: []const f64) !f64 {
    var total: f64 = 0;
    for (values) |value| total = try checkedSum(total, value);
    return total;
}

fn checkedProduct(left: f64, right: f64) !f64 {
    const result = left * right;
    if (!std.math.isFinite(result))
        return error.NonFiniteSnowBoundaryResult;
    return result;
}

fn checkedSum(current: f64, increment: f64) !f64 {
    const result = current + increment;
    if (!std.math.isFinite(result))
        return error.NonFiniteSnowBoundaryResult;
    return result;
}

fn validateFiniteStruct(value: anytype) !void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field|
        if (!std.math.isFinite(@field(value, field.name)))
            return error.InvalidSnowBoundaryInput;
}

fn positiveFinite(value: f64) bool {
    return std.math.isFinite(value) and value > 0;
}

fn nonnegativeFinite(value: f64) bool {
    return std.math.isFinite(value) and value >= 0;
}

fn filled(comptime T: type, value: f64) T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field|
        @field(result, field.name) = value;
    return result;
}

fn allOneFlux() BoundaryFlux {
    return .{
        .phases = .{
            .snow_m3_per_step = 1,
            .liquid_water_m3_per_step = 2,
            .ice_m3_per_step = 3,
            .heat_megajoules_per_step = 5,
        },
        .elements = filled(ElementFlux, 1),
        .multiplicity_one = filled(MultiplicityOneSaltFlux, 1),
        .multiplicity_two = filled(MultiplicityTwoSaltFlux, 1),
        .multiplicity_three = filled(MultiplicityThreeSaltFlux, 1),
        .multiplicity_four = filled(MultiplicityFourSaltFlux, 1),
        .multiplicity_five = filled(MultiplicityFiveSaltFlux, 1),
    };
}

fn oneCellInputs(
    salt_equilibrium_mode: SaltEquilibriumMode,
    east: []const BoundaryFlux,
    zero: []const BoundaryFlux,
) Inputs {
    return .{
        .lon_count = 1,
        .lat_count = 1,
        .external_boundary_window = .{
            .first_column = 0,
            .last_column_inclusive = 0,
            .first_row = 0,
            .last_row_inclusive = 0,
        },
        .flux_by_face = .{ east, zero, zero, zero },
        .negligible_water_m3_by_cell = &.{0},
        .ice_water_equivalent_ratio = 0.5,
        .phosphorus_g_p_per_mol_p = 31,
        .salt_equilibrium_mode = salt_equilibrium_mode,
    };
}

test "REDIST snow boundary accounts water heat elements and dynamic salts" {
    const east = [_]BoundaryFlux{allOneFlux()};
    const zero = [_]BoundaryFlux{.{}};
    var cells = [_]CellOutwardLedger{.{}};
    var state: State = .{ .cumulative = .{}, .outward_by_cell = &cells };

    try apply(oneCellInputs(.dynamic, &east, &zero), &state);

    try std.testing.expectEqual(@as(f64, 4.5), state.cumulative.water_equivalent_m3);
    try std.testing.expectEqual(@as(f64, 5), state.cumulative.heat_megajoules);
    try std.testing.expectEqual(@as(f64, 2), state.cumulative.carbon_g_c);
    try std.testing.expectEqual(@as(f64, 5), state.cumulative.nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 219), state.cumulative.phosphorus_g_p);
    try std.testing.expectEqual(@as(f64, 1), state.cumulative.oxygen_g_o);
    try std.testing.expectEqual(@as(f64, 93), state.cumulative.ion_components_mol);
    try std.testing.expectEqual(@as(f64, 2), cells[0].dissolved_inorganic_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 5), cells[0].dissolved_inorganic_nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 2), cells[0].dissolved_inorganic_phosphorus_g_p);
}

test "static salts are excluded while physical and elemental ledgers advance" {
    const east = [_]BoundaryFlux{allOneFlux()};
    const zero = [_]BoundaryFlux{.{}};
    var cells = [_]CellOutwardLedger{.{}};
    var state: State = .{ .cumulative = .{}, .outward_by_cell = &cells };

    try apply(oneCellInputs(.static, &east, &zero), &state);

    try std.testing.expectEqual(@as(f64, 2), state.cumulative.phosphorus_g_p);
    try std.testing.expectEqual(@as(f64, 0), state.cumulative.ion_components_mol);
    try std.testing.expectEqual(@as(f64, 0), cells[0].ion_components_mol);
    try std.testing.expectEqual(@as(f64, 4.5), cells[0].water_equivalent_m3);
}

test "west face signed transfer records outward drift without sign loss" {
    const west = [_]BoundaryFlux{.{
        .phases = .{
            .snow_m3_per_step = -1,
            .heat_megajoules_per_step = -2,
        },
        .elements = .{ .carbon_dioxide_g_c_per_step = -3 },
    }};
    const zero = [_]BoundaryFlux{.{}};
    var cells = [_]CellOutwardLedger{.{}};
    var state: State = .{ .cumulative = .{}, .outward_by_cell = &cells };
    var inputs = oneCellInputs(.static, &zero, &zero);
    inputs.flux_by_face = .{ &zero, &west, &zero, &zero };

    try apply(inputs, &state);

    try std.testing.expectEqual(@as(f64, 1), state.cumulative.water_equivalent_m3);
    try std.testing.expectEqual(@as(f64, 2), state.cumulative.heat_megajoules);
    try std.testing.expectEqual(@as(f64, 3), state.cumulative.carbon_g_c);
    try std.testing.expectEqual(@as(f64, 3), cells[0].dissolved_inorganic_carbon_g_c);
}

test "strict water threshold suppresses all coupled boundary ledgers" {
    const east = [_]BoundaryFlux{allOneFlux()};
    const zero = [_]BoundaryFlux{.{}};
    var cells = [_]CellOutwardLedger{.{}};
    var state: State = .{ .cumulative = .{}, .outward_by_cell = &cells };
    var inputs = oneCellInputs(.dynamic, &east, &zero);
    inputs.negligible_water_m3_by_cell = &.{4.5};

    try apply(inputs, &state);

    try std.testing.expectEqualDeep(CumulativeOutwardLedger{}, state.cumulative);
    try std.testing.expectEqualDeep(CellOutwardLedger{}, cells[0]);
}

test "runtime grid indexes boundary cells and conserves cell totals" {
    const east = [_]BoundaryFlux{ .{}, allOneFlux(), .{}, allOneFlux() };
    const zero = [_]BoundaryFlux{ .{}, .{}, .{}, .{} };
    var cells = [_]CellOutwardLedger{ .{}, .{}, .{}, .{} };
    var state: State = .{ .cumulative = .{}, .outward_by_cell = &cells };
    try apply(.{
        .lon_count = 2,
        .lat_count = 2,
        .external_boundary_window = .{
            .first_column = 0,
            .last_column_inclusive = 1,
            .first_row = 0,
            .last_row_inclusive = 1,
        },
        .flux_by_face = .{ &east, &zero, &zero, &zero },
        .negligible_water_m3_by_cell = &.{ 0, 0, 0, 0 },
        .ice_water_equivalent_ratio = 0.5,
        .phosphorus_g_p_per_mol_p = 31,
        .salt_equilibrium_mode = .dynamic,
    }, &state);

    var cell_water_total_m3: f64 = 0;
    var cell_ion_total_mol: f64 = 0;
    for (cells) |cell| {
        cell_water_total_m3 += cell.water_equivalent_m3;
        cell_ion_total_mol += cell.ion_components_mol;
    }
    try std.testing.expectEqual(state.cumulative.water_equivalent_m3, cell_water_total_m3);
    try std.testing.expectEqual(state.cumulative.ion_components_mol, cell_ion_total_mol);
    try std.testing.expectEqual(@as(f64, 0), cells[0].water_equivalent_m3);
    try std.testing.expectEqual(@as(f64, 4.5), cells[1].water_equivalent_m3);
    try std.testing.expectEqual(@as(f64, 0), cells[2].water_equivalent_m3);
    try std.testing.expectEqual(@as(f64, 4.5), cells[3].water_equivalent_m3);
}

test "late non-finite snow flux leaves every ledger unchanged" {
    var east = [_]BoundaryFlux{ allOneFlux(), allOneFlux() };
    east[1].multiplicity_five.iron_hydroxide_4_mol_per_step =
        std.math.nan(f64);
    const zero = [_]BoundaryFlux{ .{}, .{} };
    var cells = [_]CellOutwardLedger{ .{ .water_equivalent_m3 = 2 }, .{} };
    var state: State = .{
        .cumulative = .{ .water_equivalent_m3 = 3 },
        .outward_by_cell = &cells,
    };
    try std.testing.expectError(error.InvalidSnowBoundaryInput, apply(.{
        .lon_count = 2,
        .lat_count = 1,
        .external_boundary_window = .{
            .first_column = 0,
            .last_column_inclusive = 1,
            .first_row = 0,
            .last_row_inclusive = 0,
        },
        .flux_by_face = .{ &east, &zero, &zero, &zero },
        .negligible_water_m3_by_cell = &.{ 0, 0 },
        .ice_water_equivalent_ratio = 0.5,
        .phosphorus_g_p_per_mol_p = 31,
        .salt_equilibrium_mode = .dynamic,
    }, &state));
    try std.testing.expectEqual(@as(f64, 3), state.cumulative.water_equivalent_m3);
    try std.testing.expectEqual(@as(f64, 2), cells[0].water_equivalent_m3);
    try std.testing.expectEqualDeep(CellOutwardLedger{}, cells[1]);
}

test "invalid runtime ratio and boundary window fail explicitly" {
    const zero = [_]BoundaryFlux{.{}};
    var cells = [_]CellOutwardLedger{.{}};
    var state: State = .{ .cumulative = .{}, .outward_by_cell = &cells };
    var inputs = oneCellInputs(.dynamic, &zero, &zero);
    inputs.ice_water_equivalent_ratio = 1.1;
    try std.testing.expectError(
        error.InvalidSnowBoundaryInput,
        apply(inputs, &state),
    );
    inputs.ice_water_equivalent_ratio = 0.5;
    inputs.external_boundary_window.first_column = 1;
    try std.testing.expectError(
        error.InvalidSnowBoundaryWindow,
        apply(inputs, &state),
    );
}

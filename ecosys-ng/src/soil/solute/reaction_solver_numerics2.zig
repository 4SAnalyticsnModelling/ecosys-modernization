//! `reaction_solver` declarations: numerics2.
//!
//! Split out of `reaction_solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const aqueous_network = @import("aqueous_network.zig");
const phosphate_network = @import("phosphate_network.zig");
const cation_exchange = @import("cation_exchange.zig");
const geochemistry = @import("geochemistry_network.zig");
const aqueous_rates = @import("aqueous_reaction_rates.zig");
const phosphate_rates = @import("phosphate_reaction_rates.zig");
const geochemistry_rates = @import("geochemistry_reaction_rates.zig");
const water_equilibrium = @import("water_equilibrium.zig");
const reaction_span = @import("reaction_search_span.zig");

/// Includes every positive f64 power-of-two fraction down to the minimum
/// subnormal. This is an admissibility search bound, not a nonlinear
/// iteration ceiling.
pub const maximum_admissibility_backtracks: u16 = 1075;

/// Returns the representable midpoint strictly between a known admissible
/// positive fraction and a known inadmissible positive fraction. `null`
/// means the two fractions are adjacent in the f64 lattice, so `lower` is
/// the greatest representable admissible fraction in this bracket.
///
/// Positive finite IEEE-754 values have the same ordering as their unsigned
/// bit patterns. Searching those patterns avoids a tolerance-dependent
/// interior endpoint and has an inherent upper bound of 63 predicate calls.
pub fn admissibilityFractionMidpoint(lower: f64, upper: f64) ?f64 {
    std.debug.assert(std.math.isFinite(lower) and lower >= 0);
    std.debug.assert(std.math.isFinite(upper) and upper > lower);
    const lower_bits: u64 = @bitCast(lower);
    const upper_bits: u64 = @bitCast(upper);
    if (upper_bits - lower_bits <= 1) return null;
    return @bitCast(lower_bits + (upper_bits - lower_bits) / 2);
}

test "admissibility midpoint searches the exact positive f64 lattice" {
    const ordinary = admissibilityFractionMidpoint(0.25, 0.5).?;
    try std.testing.expect(ordinary > 0.25 and ordinary < 0.5);

    const ordinary_successor = std.math.nextAfter(
        f64,
        0.25,
        std.math.inf(f64),
    );
    try std.testing.expect(admissibilityFractionMidpoint(
        0.25,
        ordinary_successor,
    ) == null);

    const minimum_normal = std.math.floatMin(f64);
    const maximum_subnormal = std.math.nextAfter(f64, minimum_normal, 0);
    try std.testing.expect(admissibilityFractionMidpoint(
        maximum_subnormal,
        minimum_normal,
    ) == null);

    const subnormal = admissibilityFractionMidpoint(
        std.math.floatTrueMin(f64),
        minimum_normal,
    ).?;
    try std.testing.expect(subnormal > std.math.floatTrueMin(f64));
    try std.testing.expect(subnormal < minimum_normal);
}

pub fn maximumAqueousCalciumExtent(
    vector: []const f64,
    comptime ligand_name: []const u8,
    comptime pair_name: []const u8,
    direction: f64,
) f64 {
    return maximumAqueousAssociationExtent(
        vector,
        "calcium",
        ligand_name,
        pair_name,
        direction,
    );
}

fn maximumAqueousAssociationExtent(
    vector: []const f64,
    comptime first_name: []const u8,
    comptime second_name: []const u8,
    comptime product_name: []const u8,
    direction: f64,
) f64 {
    if (direction > 0) return @min(
        vector[aqueousPackedIndex(first_name)],
        vector[aqueousPackedIndex(second_name)],
    );
    return vector[aqueousPackedIndex(product_name)];
}

pub fn aqueousPackedIndex(comptime field_name: []const u8) usize {
    return std.meta.fieldIndex(aqueous_network.State, field_name).?;
}

pub fn hasKineticGeochemistry(parameters: chemistry.ReactionParameters) bool {
    const kinetics = parameters.geochemistry_kinetics;
    return kinetics.maximum_hydroxide_mineral_mol_per_m3_step > 0 or
        kinetics.maximum_general_mineral_mol_per_m3_step > 0 or
        kinetics.maximum_natural_weathering_mol_per_m3_step > 0 or
        kinetics.maximum_ground_weathering_mol_per_m3_step > 0;
}

pub fn scaled(transformations: chemistry.CellTransformations, fraction: f64) chemistry.CellTransformations {
    if (fraction == 1) return transformations;
    var result = transformations;
    scaleStruct(aqueous_network.Transformations, &result.aqueous, fraction);
    scaleStruct(phosphate_network.Transformations, &result.non_band_phosphate, fraction);
    scaleStruct(phosphate_network.Transformations, &result.band_phosphate, fraction);
    scaleStruct(cation_exchange.Cations, &result.cation_adsorption_mol_per_megagram, fraction);
    scaleStruct(geochemistry.Transformations, &result.geochemistry, fraction);
    result.carboxyl_hydrogen_change_mol_per_megagram *= fraction;
    return result;
}

fn scaleStruct(comptime T: type, value: *T, fraction: f64) void {
    const fields = @typeInfo(T).@"struct".fields;
    comptime {
        if (@sizeOf(T) != fields.len * @sizeOf(f64))
            @compileError("reaction transformation fields must be contiguous f64 values");
        for (fields, 0..) |field, index| {
            if (field.type != f64 or @offsetOf(T, field.name) != index * @sizeOf(f64))
                @compileError("reaction transformation layout is not source-order contiguous f64");
        }
    }
    const components: *[fields.len]f64 = @ptrCast(value);
    scaleComponents(components[0..], fraction);
}

noinline fn scaleComponents(components: []f64, fraction: f64) void {
    for (components) |*component| component.* *= fraction;
}

fn scaledSourceOrderReferenceForTest(transformations: chemistry.CellTransformations, fraction: f64) chemistry.CellTransformations {
    if (fraction == 1) return transformations;
    var result = transformations;
    inline for (@typeInfo(aqueous_network.Transformations).@"struct".fields) |field|
        @field(result.aqueous, field.name) *= fraction;
    inline for (@typeInfo(phosphate_network.Transformations).@"struct".fields) |field|
        @field(result.non_band_phosphate, field.name) *= fraction;
    inline for (@typeInfo(phosphate_network.Transformations).@"struct".fields) |field|
        @field(result.band_phosphate, field.name) *= fraction;
    inline for (@typeInfo(cation_exchange.Cations).@"struct".fields) |field|
        @field(result.cation_adsorption_mol_per_megagram, field.name) *= fraction;
    inline for (@typeInfo(geochemistry.Transformations).@"struct".fields) |field|
        @field(result.geochemistry, field.name) *= fraction;
    result.carboxyl_hydrogen_change_mol_per_megagram *= fraction;
    return result;
}

pub fn filled(comptime T: type, value: f64) T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| @field(result, field.name) = value;
    return result;
}

pub fn inorganicCarbonMolPerM3(state: *const chemistry.State, cell: usize) f64 {
    const aqueous = state.aqueous[cell];
    return aqueous.carbon_dioxide +
        aqueous.carbonate +
        aqueous.bicarbonate +
        aqueous.calcium_carbonate +
        aqueous.calcium_bicarbonate +
        aqueous.magnesium_carbonate +
        aqueous.magnesium_bicarbonate +
        aqueous.sodium_carbonate +
        state.geochemistry_solids[cell].calcite_solid_mol_per_m3;
}

test "scaled at one preserves every input bit including signed zero and nonfinite values" {
    var transformations: chemistry.CellTransformations = .{
        .aqueous = filled(aqueous_network.Transformations, 0.25),
        .non_band_phosphate = filled(phosphate_network.Transformations, 0.5),
        .band_phosphate = filled(phosphate_network.Transformations, 0.75),
        .non_band_phosphate_water_fraction = 0.3,
        .band_phosphate_water_fraction = 0.7,
        .cation_adsorption_mol_per_megagram = filled(cation_exchange.Cations, 1.25),
        .cation_exchange_water_ratios = .{ .shared_megagrams_per_m3 = 1, .ammonium_non_band_megagrams_per_m3 = 2, .ammonium_band_megagrams_per_m3 = 3 },
        .geochemistry = filled(geochemistry.Transformations, 1.5),
        .carboxyl_hydrogen_change_mol_per_megagram = 2,
        .carboxyl_soil_mass_per_water_volume_megagrams_per_m3 = 4,
    };
    const payload_nan: f64 = @bitCast(@as(u64, 0x7ff8_0000_0000_1234));
    transformations.aqueous.ammonium_non_band = -0.0;
    transformations.non_band_phosphate.dissolved_po4_mol_p_per_m3 = std.math.inf(f64);
    transformations.band_phosphate.dissolved_hpo4_mol_p_per_m3 = -std.math.inf(f64);
    transformations.geochemistry.dissolved_aluminum_mol_per_m3 = payload_nan;

    const before = transformations;
    const result = scaled(transformations, 1);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&transformations));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&result));
}

test "runtime transformation scaling preserves source-order bits" {
    var transformations: chemistry.CellTransformations = .{
        .aqueous = filled(aqueous_network.Transformations, 0.25),
        .non_band_phosphate = filled(phosphate_network.Transformations, -0.5),
        .band_phosphate = filled(phosphate_network.Transformations, 0.75),
        .non_band_phosphate_water_fraction = 0.3,
        .band_phosphate_water_fraction = 0.7,
        .cation_adsorption_mol_per_megagram = filled(cation_exchange.Cations, -1.25),
        .cation_exchange_water_ratios = .{ .shared_megagrams_per_m3 = 1, .ammonium_non_band_megagrams_per_m3 = 2, .ammonium_band_megagrams_per_m3 = 3 },
        .geochemistry = filled(geochemistry.Transformations, 1.5),
        .carboxyl_hydrogen_change_mol_per_megagram = -2,
        .carboxyl_soil_mass_per_water_volume_megagrams_per_m3 = 4,
    };
    transformations.aqueous.ammonium_non_band = -0.0;
    transformations.non_band_phosphate.dissolved_po4_mol_p_per_m3 =
        std.math.inf(f64);
    transformations.band_phosphate.dissolved_hpo4_mol_p_per_m3 =
        -std.math.inf(f64);
    transformations.geochemistry.dissolved_aluminum_mol_per_m3 =
        @bitCast(@as(u64, 0x7ff8_0000_0000_1234));
    for ([_]f64{
        0.5,
        0.1,
        std.math.scalbn(@as(f64, 1), -100),
        -0.0,
    }) |fraction| {
        const expected = scaledSourceOrderReferenceForTest(
            transformations,
            fraction,
        );
        const actual = scaled(transformations, fraction);
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&expected),
            std.mem.asBytes(&actual),
        );
    }
}

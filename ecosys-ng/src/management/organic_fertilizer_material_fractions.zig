const std = @import("std");

pub const Fractions = struct {
    protein: f64,
    soluble_carbohydrate: f64,
    cellulose: f64,
    lignin: f64,
};

pub const Parameters = struct {
    plant_by_type_one_through_eight: [8]Fractions,
    default_plant: Fractions,
    ruminant_manure: Fractions,
    other_manure: Fractions,
};

/// Compatibility defaults for `hour1.f` lines 648--750. Production callers must
/// obtain an equivalent record from compulsory runtime configuration.
pub fn sourceParameters() Parameters {
    return .{
        .plant_by_type_one_through_eight = .{
            .{ .protein = 0.080, .soluble_carbohydrate = 0.245, .cellulose = 0.613, .lignin = 0.062 },
            .{ .protein = 0.125, .soluble_carbohydrate = 0.171, .cellulose = 0.560, .lignin = 0.144 },
            .{ .protein = 0.138, .soluble_carbohydrate = 0.426, .cellulose = 0.316, .lignin = 0.120 },
            .{ .protein = 0.075, .soluble_carbohydrate = 0.125, .cellulose = 0.550, .lignin = 0.250 },
            .{ .protein = 0.036, .soluble_carbohydrate = 0.044, .cellulose = 0.767, .lignin = 0.153 },
            .{ .protein = 0.143, .soluble_carbohydrate = 0.015, .cellulose = 0.640, .lignin = 0.202 },
            .{ .protein = 0.202, .soluble_carbohydrate = 0.013, .cellulose = 0.560, .lignin = 0.225 },
            .{ .protein = 0, .soluble_carbohydrate = 1, .cellulose = 0, .lignin = 0 },
        },
        .default_plant = .{ .protein = 0.075, .soluble_carbohydrate = 0.125, .cellulose = 0.550, .lignin = 0.250 },
        .ruminant_manure = .{ .protein = 0.036, .soluble_carbohydrate = 0.044, .cellulose = 0.630, .lignin = 0.290 },
        .other_manure = .{ .protein = 0.138, .soluble_carbohydrate = 0.401, .cellulose = 0.316, .lignin = 0.145 },
    };
}

/// Exact HOUR1 plant-residue type branches at lines 648--714.
pub fn plant(material_type: u8, parameters: Parameters) !Fractions {
    try validate(parameters);
    return if (material_type >= 1 and material_type <= 8)
        parameters.plant_by_type_one_through_eight[material_type - 1]
    else
        parameters.default_plant;
}

/// Exact HOUR1 manure branches at lines 721--750. Types one and three share
/// the ruminant row; type two and all other codes use the other row.
pub fn manure(material_type: u8, parameters: Parameters) !Fractions {
    try validate(parameters);
    return if (material_type == 1 or material_type == 3)
        parameters.ruminant_manure
    else
        parameters.other_manure;
}

fn validate(parameters: Parameters) !void {
    for (parameters.plant_by_type_one_through_eight) |fractions|
        try validateFractions(fractions);
    try validateFractions(parameters.default_plant);
    try validateFractions(parameters.ruminant_manure);
    try validateFractions(parameters.other_manure);
}

fn validateFractions(fractions: Fractions) !void {
    var total: f64 = 0;
    inline for (@typeInfo(Fractions).@"struct".fields) |field| {
        const value = @field(fractions, field.name);
        if (!std.math.isFinite(value))
            return error.NonFiniteOrganicMaterialFraction;
        if (value < 0 or value > 1)
            return error.InvalidOrganicMaterialFraction;
        total += value;
    }
    if (!std.math.isFinite(total) or @abs(total - 1) > 1.0e-12)
        return error.InvalidOrganicMaterialFractionTotal;
}

test "all source plant material rows preserve exact assignments" {
    const parameters = sourceParameters();
    for (1..9) |material_type| {
        const selected = try plant(@intCast(material_type), parameters);
        try std.testing.expectEqual(
            parameters.plant_by_type_one_through_eight[material_type - 1],
            selected,
        );
    }
    try std.testing.expectEqual(parameters.default_plant, try plant(9, parameters));
    try std.testing.expectEqual(parameters.default_plant, try plant(10, parameters));
}

test "manure type three retains source ruminant row" {
    const parameters = sourceParameters();
    try std.testing.expectEqual(parameters.ruminant_manure, try manure(1, parameters));
    try std.testing.expectEqual(parameters.other_manure, try manure(2, parameters));
    try std.testing.expectEqual(parameters.ruminant_manure, try manure(3, parameters));
    try std.testing.expectEqual(parameters.other_manure, try manure(4, parameters));
}

test "invalid runtime fraction table fails explicitly" {
    var parameters = sourceParameters();
    parameters.plant_by_type_one_through_eight[7].soluble_carbohydrate = 0.9;
    try std.testing.expectError(
        error.InvalidOrganicMaterialFractionTotal,
        plant(8, parameters),
    );
}

const std = @import("std");
const PlantTraits = @import("../../state/plant_traits.zig").PlantTraits;
const KineticParameters = @import("../initialization/seed_and_population.zig").StandingDeadPartitionParameters;

pub const kinetic_component_count: usize = 4;

pub const Organ = enum(u8) {
    nonstructural,
    foliar,
    non_foliar,
    stalk,
    fine_root,
    coarse_wood,

    pub const count: usize = @typeInfo(Organ).@"enum".fields.len;
};

pub const ElementFractions = struct {
    carbon: [kinetic_component_count]f64,
    nitrogen: [kinetic_component_count]f64,
    phosphorus: [kinetic_component_count]f64,

    pub fn validate(self: ElementFractions) !void {
        inline for (.{ self.carbon, self.nitrogen, self.phosphorus }) |fractions| {
            var sum: f64 = 0;
            for (fractions) |fraction| {
                if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidPlantLitterFraction;
                sum += fraction;
            }
            if (@abs(sum - 1) > 1e-12) return error.NonConservativePlantLitterFractions;
        }
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    plant_count: usize,
    by_plant_and_organ: []ElementFractions,

    pub fn init(allocator: std.mem.Allocator, plant_count: usize) !State {
        if (plant_count == 0) return error.ZeroPlantCount;
        const values = try allocator.alloc(ElementFractions, try std.math.mul(usize, plant_count, Organ.count));
        // Runtime plant slots can be intentionally inactive in a management
        // unit. Give those zero-biomass slots a conservative carbohydrate
        // partition so grid-wide disturbance kernels need no sentinel branch.
        @memset(values, .{
            .carbon = .{ 0, 1, 0, 0 },
            .nitrogen = .{ 0, 1, 0, 0 },
            .phosphorus = .{ 0, 1, 0, 0 },
        });
        return .{ .allocator = allocator, .plant_count = plant_count, .by_plant_and_organ = values };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.by_plant_and_organ);
        self.* = undefined;
    }

    pub fn initializePlant(self: *State, plant: usize, traits: PlantTraits, parameters: KineticParameters) !void {
        if (plant >= self.plant_count) return error.PlantIndexOutOfBounds;
        try parameters.validate();
        const carbon = carbonFractions(traits, parameters);
        for (carbon, 0..) |fractions, organ| self.by_plant_and_organ[plant * Organ.count + organ] = try withNutrients(fractions, parameters);
    }

    pub fn get(self: State, plant: usize, organ: Organ) !ElementFractions {
        if (plant >= self.plant_count) return error.PlantIndexOutOfBounds;
        const result = self.by_plant_and_organ[plant * Organ.count + @intFromEnum(organ)];
        try result.validate();
        return result;
    }
};

/// Exact STARTQ CFOPC(0:5,1:4) branch table. Components are protein,
/// carbohydrate, cellulose, and lignin, respectively.
pub fn carbonFractions(traits: PlantTraits, parameters: KineticParameters) [Organ.count][kinetic_component_count]f64 {
    const nonstructural = [4]f64{ 0, 1, 0, 0 };
    const coarse_wood = parameters.carbon_fraction;
    const nonvascular = traits.functional_type.root_profile_type == 0;
    const legume = traits.functional_type.nitrogen_fixation_type != 0;
    const annual_grass_or_shrub = traits.functional_type.aboveground_turnover_type == 0 or traits.functional_type.root_profile_type <= 1;
    const deciduous_tree = traits.functional_type.aboveground_turnover_type == 1 or traits.functional_type.aboveground_turnover_type >= 3;

    const foliar: [4]f64 = if (nonvascular)
        .{ 0.07, 0.25, 0.30, 0.38 }
    else if (legume)
        .{ 0.16, 0.38, 0.34, 0.12 }
    else if (annual_grass_or_shrub)
        .{ 0.08, 0.41, 0.36, 0.15 }
    else if (deciduous_tree)
        .{ 0.07, 0.34, 0.36, 0.23 }
    else
        .{ 0.07, 0.25, 0.38, 0.30 };
    const non_foliar: [4]f64 = if (nonvascular)
        .{ 0.07, 0.25, 0.30, 0.38 }
    else if (legume)
        .{ 0.07, 0.41, 0.37, 0.15 }
    else if (annual_grass_or_shrub)
        .{ 0.07, 0.41, 0.36, 0.16 }
    else
        coarse_wood;
    const stalk: [4]f64 = if (nonvascular)
        .{ 0.07, 0.25, 0.30, 0.38 }
    else if (annual_grass_or_shrub)
        .{ 0.03, 0.25, 0.57, 0.15 }
    else
        coarse_wood;
    const fine_root: [4]f64 = if (nonvascular)
        .{ 0.07, 0.25, 0.30, 0.38 }
    else if (annual_grass_or_shrub)
        .{ 0.057, 0.263, 0.542, 0.138 }
    else if (deciduous_tree)
        .{ 0.059, 0.308, 0.464, 0.169 }
    else
        .{ 0.07, 0.25, 0.38, 0.30 };
    return .{ nonstructural, foliar, non_foliar, stalk, fine_root, coarse_wood };
}

fn withNutrients(carbon: [4]f64, parameters: KineticParameters) !ElementFractions {
    const result: ElementFractions = .{
        .carbon = carbon,
        .nitrogen = try normalizedWeighted(carbon, parameters.nitrogen_weight),
        .phosphorus = try normalizedWeighted(carbon, parameters.phosphorus_weight),
    };
    try result.validate();
    return result;
}

fn normalizedWeighted(base: [4]f64, weights: [4]f64) ![4]f64 {
    var denominator: f64 = 0;
    for (base, weights) |fraction, weight| denominator += fraction * weight;
    if (!std.math.isFinite(denominator) or denominator <= 0) return error.InvalidPlantLitterWeights;
    var result: [4]f64 = undefined;
    for (&result, base, weights) |*fraction, source, weight| fraction.* = source * weight / denominator;
    return result;
}

fn traitsFor(root_profile: u8, nitrogen_fixation: u8, turnover: u8) PlantTraits {
    var traits = std.mem.zeroes(PlantTraits);
    traits.functional_type.root_profile_type = root_profile;
    traits.functional_type.nitrogen_fixation_type = nitrogen_fixation;
    traits.functional_type.aboveground_turnover_type = turnover;
    return traits;
}

test "STARTQ litter table preserves every source vegetation branch" {
    const parameters = @import("../initialization/seed_and_population.zig").compatibilityStandingDeadPartitionParameters();
    const moss = carbonFractions(traitsFor(0, 0, 0), parameters);
    try std.testing.expectEqual([4]f64{ 0.07, 0.25, 0.30, 0.38 }, moss[@intFromEnum(Organ.foliar)]);
    const legume = carbonFractions(traitsFor(2, 1, 0), parameters);
    try std.testing.expectEqual([4]f64{ 0.16, 0.38, 0.34, 0.12 }, legume[@intFromEnum(Organ.foliar)]);
    const annual = carbonFractions(traitsFor(2, 0, 0), parameters);
    try std.testing.expectEqual([4]f64{ 0.057, 0.263, 0.542, 0.138 }, annual[@intFromEnum(Organ.fine_root)]);
    const deciduous = carbonFractions(traitsFor(2, 0, 1), parameters);
    try std.testing.expectEqual([4]f64{ 0.059, 0.308, 0.464, 0.169 }, deciduous[@intFromEnum(Organ.fine_root)]);
    const conifer = carbonFractions(traitsFor(2, 0, 2), parameters);
    try std.testing.expectEqual([4]f64{ 0.07, 0.25, 0.38, 0.30 }, conifer[@intFromEnum(Organ.fine_root)]);
}

test "runtime plant litter state normalizes C N P independently beyond five species" {
    var state = try State.init(std.testing.allocator, 11);
    defer state.deinit();
    const parameters = @import("../initialization/seed_and_population.zig").compatibilityStandingDeadPartitionParameters();
    for (0..state.plant_count) |plant| try state.initializePlant(plant, traitsFor(2, 0, if (plant % 2 == 0) 1 else 2), parameters);
    for (0..state.plant_count) |plant| for (0..Organ.count) |organ| try (try state.get(plant, @enumFromInt(organ))).validate();
}

test "STARTQ runtime kinetic parameters govern coarse wood and all nutrient partitions" {
    const parameters: KineticParameters = .{
        .carbon_fraction = .{ 0.1, 0.2, 0.3, 0.4 },
        .nitrogen_weight = .{ 1, 2, 3, 4 },
        .phosphorus_weight = .{ 4, 3, 2, 1 },
    };
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try state.initializePlant(0, traitsFor(2, 0, 2), parameters);
    const coarse = try state.get(0, .coarse_wood);
    try std.testing.expectEqual(parameters.carbon_fraction, coarse.carbon);
    const foliar = try state.get(0, .foliar);
    try std.testing.expectEqual(try normalizedWeighted(foliar.carbon, parameters.nitrogen_weight), foliar.nitrogen);
    try std.testing.expectEqual(try normalizedWeighted(foliar.carbon, parameters.phosphorus_weight), foliar.phosphorus);
}

const std = @import("std");

pub const organ_count: usize = 7;

pub const Parameters = struct {
    initial_leaf_fraction: f64,
    initial_sheath_fraction: f64,
    minimum_leaf_fraction_by_determinacy: [2]f64,
    minimum_sheath_fraction_by_determinacy: [2]f64,
    leaf_reduction_by_turnover: [6]f64,
    sheath_reduction_by_turnover: [6]f64,
    low_reserve_carbon_per_sapwood_g_c_per_g_c: f64,
    low_reserve_redirect_fraction: f64,

    pub fn validate(self: Parameters) !void {
        inline for (@typeInfo(Parameters).@"struct".fields) |field| {
            if (field.type == f64) {
                const value = @field(self, field.name);
                if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidOrganPartitionParameter;
            } else for (@field(self, field.name)) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganPartitionParameter;
        }
        if (self.initial_leaf_fraction + self.initial_sheath_fraction > 1 + 1.0e-12) return error.InvalidOrganPartitionParameter;
    }
};

pub fn compatibilityParameters() Parameters {
    return .{
        .initial_leaf_fraction = 0.75,
        .initial_sheath_fraction = 0.25,
        .minimum_leaf_fraction_by_determinacy = .{ 0.0200, 0.0500 },
        .minimum_sheath_fraction_by_determinacy = .{ 0.0067, 0.0167 },
        .leaf_reduction_by_turnover = .{ 0.75, 1.50, 2.00, 2.00, 1.75, 1.50 },
        .sheath_reduction_by_turnover = .{ 0.25, 0.50, 0.67, 0.67, 0.58, 0.50 },
        .low_reserve_carbon_per_sapwood_g_c_per_g_c = 0.10,
        .low_reserve_redirect_fraction = 0.10,
    };
}

pub const Inputs = struct {
    floral_initiation_started: bool,
    anthesis_started: bool,
    grain_fill_started: bool,
    physiological_maturity_reached: bool,
    determinate: bool,
    perennial: bool,
    /// IBTYP: above-ground biomass turnover-rate class (0/1=fully deciduous,
    /// 2=needleleaf evergreen, 3=broadleaf evergreen, 4=semi-deciduous,
    /// 5=semi-evergreen). Selects `leaf_reduction_by_turnover` /
    /// `sheath_reduction_by_turnover` and gates the post-maturity stalk/grain
    /// clearing block (GROSUB IBTYP.EQ.0 branch).
    turnover_type: u8,
    /// IWTYP: phenology type (0=evergreen, 1=cold deciduous, 2=drought
    /// deciduous, 3=cold and drought deciduous). Gates the autumn leaf-fall
    /// remobilization block below (GROSUB `ISTYP.NE.0.AND.IWTYP.NE.0`); this
    /// is a distinct PFT axis from `turnover_type` and must not be conflated
    /// with it.
    leaf_phenology_type: u8,
    normalized_vegetative_stage: f64,
    normalized_reproductive_stage: f64,
    internode_extension_enabled: bool,
    reserve_carbon_g_c: f64,
    sapwood_carbon_g_c: f64,
    shoot_remobilization_enabled: bool,
};

pub const Result = struct { fraction: [organ_count]f64, leaf_plus_sheath_fraction: f64 };

/// Exact GROSUB PART(1:7), ordered leaf, sheath, stalk, reserve, husk, ear,
/// grain.
pub fn calculate(parameters: Parameters, inputs: Inputs) !Result {
    try parameters.validate();
    if (inputs.turnover_type >= 6) return error.InvalidOrganPartitionCode;
    inline for (.{ inputs.normalized_vegetative_stage, inputs.normalized_reproductive_stage, inputs.reserve_carbon_g_c, inputs.sapwood_carbon_g_c }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganPartitionInput;
    const determinacy: usize = @intFromBool(!inputs.determinate);
    var part = [_]f64{0} ** organ_count;
    if (!inputs.floral_initiation_started) {
        part[0] = parameters.initial_leaf_fraction;
        part[1] = parameters.initial_sheath_fraction;
    } else if (!inputs.anthesis_started) {
        part[0] = @max(parameters.minimum_leaf_fraction_by_determinacy[determinacy], parameters.initial_leaf_fraction - parameters.leaf_reduction_by_turnover[inputs.turnover_type] * inputs.normalized_vegetative_stage);
        part[1] = @max(parameters.minimum_sheath_fraction_by_determinacy[determinacy], parameters.initial_sheath_fraction - parameters.sheath_reduction_by_turnover[inputs.turnover_type] * inputs.normalized_vegetative_stage);
        distributeBeforeGrain(&part, 1 - part[0] - part[1], inputs.internode_extension_enabled, 0);
    } else if (!inputs.grain_fill_started) {
        if (!inputs.determinate) {
            part[0] = @max(parameters.minimum_leaf_fraction_by_determinacy[determinacy], (parameters.initial_leaf_fraction - parameters.leaf_reduction_by_turnover[inputs.turnover_type]) * (1 - inputs.normalized_reproductive_stage));
            part[1] = @max(parameters.minimum_sheath_fraction_by_determinacy[determinacy], (parameters.initial_sheath_fraction - parameters.sheath_reduction_by_turnover[inputs.turnover_type]) * (1 - inputs.normalized_reproductive_stage));
        }
        distributeBeforeGrain(&part, 1 - part[0] - part[1], inputs.internode_extension_enabled, inputs.normalized_reproductive_stage);
    } else if (inputs.determinate) {
        part[6] = 1;
    } else {
        part[0] = parameters.minimum_leaf_fraction_by_determinacy[determinacy];
        part[1] = parameters.minimum_sheath_fraction_by_determinacy[determinacy];
        const remainder = 1 - part[0] - part[1];
        if (!inputs.perennial) {
            part[4] = 0.125 * remainder;
            part[5] = 0.125 * remainder;
            if (inputs.internode_extension_enabled) {
                part[2] = 0.125 * remainder;
                part[6] = 0.625 * remainder;
            } else part[6] = 0.750 * remainder;
        } else if (inputs.internode_extension_enabled) {
            part[2] = 0.75 * remainder;
            part[6] = 0.25 * remainder;
        } else part[6] = remainder;
    }
    if (inputs.turnover_type == 0 and inputs.physiological_maturity_reached) {
        if (inputs.perennial) part[3] += part[2];
        part[2] = 0;
        part[6] = 0;
        if (!inputs.perennial) part[3] = 0;
    }
    if (inputs.floral_initiation_started) {
        if (inputs.reserve_carbon_g_c < parameters.low_reserve_carbon_per_sapwood_g_c_per_g_c * inputs.sapwood_carbon_g_c) {
            for (0..organ_count) |organ| if (organ != 3) {
                const redirected = parameters.low_reserve_redirect_fraction * part[organ];
                part[3] += redirected;
                part[organ] -= redirected;
            };
        } else if (inputs.reserve_carbon_g_c > inputs.sapwood_carbon_g_c) {
            const released = part[3] + part[6];
            if (inputs.internode_extension_enabled) part[2] += released else {
                part[0] += parameters.initial_leaf_fraction * released;
                part[1] += parameters.initial_sheath_fraction * released;
            }
            part[3] = 0;
            part[6] = 0;
        }
    }
    if (inputs.shoot_remobilization_enabled and inputs.perennial and inputs.leaf_phenology_type != 0) {
        const released = part[0] + part[1];
        if (inputs.internode_extension_enabled) {
            part[2] += 0.5 * released;
            part[3] += 0.5 * released;
        } else part[3] += released;
        part[0] = 0;
        part[1] = 0;
    }
    var total: f64 = 0;
    for (&part) |*fraction| {
        fraction.* = @max(0, fraction.*);
        total += fraction.*;
    }
    if (!std.math.isFinite(total)) return error.NonFiniteOrganPartition;
    if (total > 0) {
        for (&part) |*fraction| fraction.* /= total;
    } else @memset(&part, 0);
    return .{ .fraction = part, .leaf_plus_sheath_fraction = part[0] + part[1] };
}

fn distributeBeforeGrain(part: *[organ_count]f64, remainder: f64, internode: bool, reproductive_stage: f64) void {
    if (internode) {
        part[2] = @max(0, 0.60 * remainder * (1 - reproductive_stage));
        part[3] = @max(0, 0.30 * remainder * (1 - reproductive_stage));
    } else part[3] = @max(0, 0.90 * remainder * (1 - reproductive_stage));
    const reproductive = remainder - part[2] - part[3];
    part[4] = 0.5 * reproductive;
    part[5] = 0.5 * reproductive;
}

fn baseInputs() Inputs {
    return .{ .floral_initiation_started = false, .anthesis_started = false, .grain_fill_started = false, .physiological_maturity_reached = false, .determinate = true, .perennial = false, .turnover_type = 0, .leaf_phenology_type = 0, .normalized_vegetative_stage = 0, .normalized_reproductive_stage = 0, .internode_extension_enabled = true, .reserve_carbon_g_c = 0, .sapwood_carbon_g_c = 0, .shoot_remobilization_enabled = false };
}

test "GROSUB partition starts with leaf and sheath" {
    const result = try calculate(compatibilityParameters(), baseInputs());
    try std.testing.expectEqual([7]f64{ 0.75, 0.25, 0, 0, 0, 0, 0 }, result.fraction);
}

test "determinate grain fill sends all growth to grain" {
    var inputs = baseInputs();
    inputs.floral_initiation_started = true;
    inputs.anthesis_started = true;
    inputs.grain_fill_started = true;
    const result = try calculate(compatibilityParameters(), inputs);
    try std.testing.expectEqual(@as(f64, 1), result.fraction[6]);
}

test "perennial deciduous remobilization redirects leaf and sheath" {
    var inputs = baseInputs();
    inputs.perennial = true;
    inputs.determinate = false;
    inputs.turnover_type = 1;
    inputs.leaf_phenology_type = 1;
    inputs.shoot_remobilization_enabled = true;
    const result = try calculate(compatibilityParameters(), inputs);
    try std.testing.expectEqual(@as(f64, 0), result.leaf_plus_sheath_fraction);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.fraction[2], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.fraction[3], 1.0e-15);
}

test "perennial fully-deciduous (IBTYP=0) cold-deciduous (IWTYP=1) still remobilizes leaf and sheath" {
    // Regression test for the IBTYP/IWTYP conflation: a perennial with
    // turnover_type (IBTYP) == 0 (fully deciduous) must still redirect
    // leaf+sheath carbon on leaf-fall because the gate is keyed on
    // leaf_phenology_type (IWTYP), not turnover_type.
    var inputs = baseInputs();
    inputs.perennial = true;
    inputs.determinate = false;
    inputs.turnover_type = 0;
    inputs.leaf_phenology_type = 1;
    inputs.shoot_remobilization_enabled = true;
    const result = try calculate(compatibilityParameters(), inputs);
    try std.testing.expectEqual(@as(f64, 0), result.leaf_plus_sheath_fraction);
}

test "leaf_phenology_type=0 (evergreen) never triggers autumn remobilization" {
    var inputs = baseInputs();
    inputs.perennial = true;
    inputs.determinate = false;
    inputs.turnover_type = 1;
    inputs.leaf_phenology_type = 0;
    inputs.shoot_remobilization_enabled = true;
    const result = try calculate(compatibilityParameters(), inputs);
    try std.testing.expect(result.leaf_plus_sheath_fraction > 0);
}

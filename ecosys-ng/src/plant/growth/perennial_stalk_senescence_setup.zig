const std = @import("std");

pub const RecyclingFractions = struct {
    carbon: f64,
    nitrogen: f64,
    phosphorus: f64,
};

pub const Inputs = struct {
    is_perennial: bool,
    excess_maintenance_respiration_g_c_per_timestep: f64,
    stalk_carbon_g_c: f64,
    sapwood_carbon_g_c: f64,
    presence_threshold_g_c: f64,
    first_internode: usize,
    last_internode: usize,
    shoot_recycling: RecyclingFractions,
};

pub const Setup = struct {
    total_respiration_g_c_per_timestep: f64,
    phenological_senescence_fraction: f64,
    sapwood_fraction_of_stalk: f64,
    sapwood_recycling: RecyclingFractions,
    first_internode: usize,
    last_internode: usize,
};

/// grosub.f lines 3283--3298. Forms SNCT before applying the perennial, demand,
/// and stalk-presence gates; then scales C/N/P recycling by sapwood fraction.
/// Explicit runtime bounds replace the source's modulo-25 ring window.
pub fn prepare(inputs: Inputs) !?Setup {
    inline for (.{
        inputs.excess_maintenance_respiration_g_c_per_timestep,
        inputs.stalk_carbon_g_c,
        inputs.sapwood_carbon_g_c,
        inputs.presence_threshold_g_c,
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteStalkSenescenceSetupInput;
    if (inputs.excess_maintenance_respiration_g_c_per_timestep < 0 or
        inputs.stalk_carbon_g_c < 0 or inputs.sapwood_carbon_g_c < 0 or
        inputs.sapwood_carbon_g_c > inputs.stalk_carbon_g_c or
        inputs.presence_threshold_g_c < 0 or
        inputs.first_internode > inputs.last_internode)
        return error.InvalidStalkSenescenceSetupInput;
    inline for (@typeInfo(RecyclingFractions).@"struct".fields) |field| {
        const value = @field(inputs.shoot_recycling, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidStalkSenescenceRecyclingFraction;
    }

    // Preserve `SNCZ=...; SNCT=SNCR+SNCZ` evaluation before the source gate.
    const phenological_respiration_g_c_per_timestep: f64 = 0;
    const total_respiration_g_c_per_timestep =
        inputs.excess_maintenance_respiration_g_c_per_timestep +
        phenological_respiration_g_c_per_timestep;
    if (!std.math.isFinite(total_respiration_g_c_per_timestep))
        return error.NonFiniteStalkSenescenceSetupResult;
    if (!inputs.is_perennial or
        total_respiration_g_c_per_timestep <= inputs.presence_threshold_g_c or
        inputs.stalk_carbon_g_c <= inputs.presence_threshold_g_c)
        return null;

    const phenological_fraction = phenological_respiration_g_c_per_timestep /
        total_respiration_g_c_per_timestep;
    const sapwood_fraction = inputs.sapwood_carbon_g_c / inputs.stalk_carbon_g_c;
    const scaled: RecyclingFractions = .{
        .carbon = inputs.shoot_recycling.carbon * sapwood_fraction,
        .nitrogen = inputs.shoot_recycling.nitrogen * sapwood_fraction,
        .phosphorus = inputs.shoot_recycling.phosphorus * sapwood_fraction,
    };
    inline for (.{
        phenological_fraction,
        sapwood_fraction,
        scaled.carbon,
        scaled.nitrogen,
        scaled.phosphorus,
    }) |value| if (!std.math.isFinite(value) or value < 0 or value > 1)
        return error.InvalidStalkSenescenceSetupResult;
    return .{
        .total_respiration_g_c_per_timestep = total_respiration_g_c_per_timestep,
        .phenological_senescence_fraction = phenological_fraction,
        .sapwood_fraction_of_stalk = sapwood_fraction,
        .sapwood_recycling = scaled,
        .first_internode = inputs.first_internode,
        .last_internode = inputs.last_internode,
    };
}

/// Returns the source-order internode for a zero-based descending iteration.
pub fn descendingInternode(setup: Setup, iteration: usize) ?usize {
    const span = setup.last_internode - setup.first_internode;
    if (iteration > span) return null;
    return setup.last_internode - iteration;
}

fn sampleInputs() Inputs {
    return .{
        .is_perennial = true,
        .excess_maintenance_respiration_g_c_per_timestep = 3,
        .stalk_carbon_g_c = 20,
        .sapwood_carbon_g_c = 5,
        .presence_threshold_g_c = 1.0e-9,
        .first_internode = 2,
        .last_internode = 30,
        .shoot_recycling = .{ .carbon = 0.8, .nitrogen = 0.6, .phosphorus = 0.4 },
    };
}

test "sapwood fraction scales each source recycling fraction" {
    const result = (try prepare(sampleInputs())).?;
    try std.testing.expectEqual(@as(f64, 3), result.total_respiration_g_c_per_timestep);
    try std.testing.expectEqual(@as(f64, 0), result.phenological_senescence_fraction);
    try std.testing.expectEqual(@as(f64, 0.25), result.sapwood_fraction_of_stalk);
    try std.testing.expectEqual(@as(f64, 0.2), result.sapwood_recycling.carbon);
    try std.testing.expectEqual(@as(f64, 0.15), result.sapwood_recycling.nitrogen);
    try std.testing.expectEqual(@as(f64, 0.1), result.sapwood_recycling.phosphorus);
}

test "descending runtime range has no legacy ring truncation" {
    const result = (try prepare(sampleInputs())).?;
    try std.testing.expectEqual(@as(?usize, 30), descendingInternode(result, 0));
    try std.testing.expectEqual(@as(?usize, 25), descendingInternode(result, 5));
    try std.testing.expectEqual(@as(?usize, 2), descendingInternode(result, 28));
    try std.testing.expectEqual(@as(?usize, null), descendingInternode(result, 29));
}

test "each source gate returns no stalk work" {
    var inputs = sampleInputs();
    inputs.is_perennial = false;
    try std.testing.expectEqual(@as(?Setup, null), try prepare(inputs));
    inputs = sampleInputs();
    inputs.excess_maintenance_respiration_g_c_per_timestep = 0;
    try std.testing.expectEqual(@as(?Setup, null), try prepare(inputs));
    inputs = sampleInputs();
    inputs.stalk_carbon_g_c = inputs.presence_threshold_g_c;
    inputs.sapwood_carbon_g_c = 0;
    try std.testing.expectEqual(@as(?Setup, null), try prepare(inputs));
}

test "zero sapwood produces zero recycling without suppressing stalk work" {
    var inputs = sampleInputs();
    inputs.sapwood_carbon_g_c = 0;
    const result = (try prepare(inputs)).?;
    try std.testing.expectEqual(@as(f64, 0), result.sapwood_recycling.carbon);
    try std.testing.expectEqual(@as(f64, 0), result.sapwood_recycling.nitrogen);
    try std.testing.expectEqual(@as(f64, 0), result.sapwood_recycling.phosphorus);
}

test "invalid physical state and runtime range fail explicitly" {
    var inputs = sampleInputs();
    inputs.sapwood_carbon_g_c = 21;
    try std.testing.expectError(error.InvalidStalkSenescenceSetupInput, prepare(inputs));
    inputs = sampleInputs();
    inputs.first_internode = 31;
    try std.testing.expectError(error.InvalidStalkSenescenceSetupInput, prepare(inputs));
    inputs = sampleInputs();
    inputs.stalk_carbon_g_c = std.math.nan(f64);
    try std.testing.expectError(error.NonFiniteStalkSenescenceSetupInput, prepare(inputs));
}

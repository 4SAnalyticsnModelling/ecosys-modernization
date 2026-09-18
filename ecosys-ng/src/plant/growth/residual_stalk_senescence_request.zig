const std = @import("std");

pub const Elements = struct { carbon: f64, nitrogen: f64, phosphorus: f64 };

pub const Request = struct {
    recyclable: Elements,
    removal_fraction: f64,
};

/// grosub.f lines 3458--3477. Calculates residual-stalk recyclable C/N/P and
/// FSNCR from the already sapwood-scaled RCSC/RCSN/RCSP. Returning null
/// preserves the strict WTSTXB > ZEROP gate and prevents double scaling.
pub fn calculate(
    residual_stalk: Elements,
    sapwood_recycling: Elements,
    respiration_demand_g_c_per_timestep: f64,
    presence_threshold_g_c: f64,
) !?Request {
    inline for (.{ residual_stalk, sapwood_recycling }) |values| inline for (@typeInfo(Elements).@"struct".fields) |field| {
        const value = @field(values, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidResidualStalkSenescenceInput;
    };
    inline for (@typeInfo(Elements).@"struct".fields) |field| if (@field(sapwood_recycling, field.name) > 1) return error.InvalidResidualStalkSenescenceInput;
    inline for (.{ respiration_demand_g_c_per_timestep, presence_threshold_g_c }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidResidualStalkSenescenceInput;
    if (residual_stalk.carbon <= presence_threshold_g_c) return null;

    const recyclable: Elements = .{
        .carbon = sapwood_recycling.carbon * residual_stalk.carbon,
        .nitrogen = residual_stalk.nitrogen * (sapwood_recycling.nitrogen + (1 - sapwood_recycling.nitrogen) * sapwood_recycling.carbon),
        .phosphorus = residual_stalk.phosphorus * (sapwood_recycling.phosphorus + (1 - sapwood_recycling.phosphorus) * sapwood_recycling.carbon),
    };
    const fraction = if (recyclable.carbon > presence_threshold_g_c)
        @max(0.0, @min(1.0, respiration_demand_g_c_per_timestep / recyclable.carbon))
    else
        1.0;
    inline for (.{ recyclable.carbon, recyclable.nitrogen, recyclable.phosphorus, fraction }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidResidualStalkSenescenceResult;
    return .{ .recyclable = recyclable, .removal_fraction = fraction };
}

test "already-scaled recycling is applied exactly once" {
    const result = (try calculate(
        .{ .carbon = 8, .nitrogen = 1, .phosphorus = 0.2 },
        .{ .carbon = 0.25, .nitrogen = 0.2, .phosphorus = 0.1 },
        1,
        0,
    )).?;
    try std.testing.expectEqual(@as(f64, 2), result.recyclable.carbon);
    try std.testing.expectEqual(@as(f64, 0.4), result.recyclable.nitrogen);
    try std.testing.expectEqual(@as(f64, 0.065), result.recyclable.phosphorus);
    try std.testing.expectEqual(@as(f64, 0.5), result.removal_fraction);
}

test "strict residual presence gate returns no request" {
    try std.testing.expectEqual(@as(?Request, null), try calculate(
        .{ .carbon = 0.01, .nitrogen = 1, .phosphorus = 1 },
        .{ .carbon = 0.5, .nitrogen = 0.5, .phosphorus = 0.5 },
        1,
        0.01,
    ));
}

test "zero recyclable carbon selects complete source removal" {
    const result = (try calculate(
        .{ .carbon = 4, .nitrogen = 1, .phosphorus = 1 },
        .{ .carbon = 0, .nitrogen = 0, .phosphorus = 0 },
        2,
        0,
    )).?;
    try std.testing.expectEqual(@as(f64, 1), result.removal_fraction);
}

test "non-finite and unscaled-invalid fractions fail explicitly" {
    try std.testing.expectError(error.InvalidResidualStalkSenescenceInput, calculate(
        .{ .carbon = std.math.nan(f64), .nitrogen = 0, .phosphorus = 0 },
        .{ .carbon = 0, .nitrogen = 0, .phosphorus = 0 },
        0,
        0,
    ));
    try std.testing.expectError(error.InvalidResidualStalkSenescenceInput, calculate(
        .{ .carbon = 1, .nitrogen = 0, .phosphorus = 0 },
        .{ .carbon = 1.1, .nitrogen = 0, .phosphorus = 0 },
        0,
        0,
    ));
}

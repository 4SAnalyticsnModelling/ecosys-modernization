const std = @import("std");
const porosity = @import("plant_root_porosity.zig");

pub const State = struct {
    /// Flattened `PORT(N,NZ)` in plant-major, biological-domain-minor order.
    current_porosity_fraction_by_domain: []f64,
};

pub const Inputs = struct {
    plant_count: usize,
    /// Prefix offsets into domain arrays; length is `plant_count + 1`.
    biological_domain_offsets_by_plant: []const usize,
    initial_porosity_fraction_by_domain: []const f64,
    /// Source `OSTR(NZ)`, shared by every biological domain of a plant.
    oxygen_satisfaction_fraction_by_plant: []const f64,
    biological_timestep_h: f64,
    parameters: porosity.Parameters,
};

/// Exact grosub.f lines 5963--5966 runtime `NZ,N` PORT adaptation sweep.
///
/// Porosity and oxygen satisfaction are dimensionless; timestep is h. A full
/// preflight preserves fail-fast atomicity while retaining source plant-outer,
/// biological-domain-inner traversal and arithmetic order.
pub fn apply(state: State, inputs: Inputs) !void {
    if (inputs.plant_count == 0 or
        inputs.biological_domain_offsets_by_plant.len != inputs.plant_count + 1 or
        inputs.oxygen_satisfaction_fraction_by_plant.len != inputs.plant_count)
        return error.RootPorositySweepDimensionMismatch;
    if (inputs.biological_domain_offsets_by_plant[0] != 0)
        return error.InvalidRootPorosityDomainOffsets;
    const domain_count = inputs.biological_domain_offsets_by_plant[inputs.plant_count];
    var previous_end: usize = 0;
    for (0..inputs.plant_count) |plant| {
        const start = inputs.biological_domain_offsets_by_plant[plant];
        const end = inputs.biological_domain_offsets_by_plant[plant + 1];
        if (start != previous_end or end <= start or end > domain_count)
            return error.InvalidRootPorosityDomainOffsets;
        previous_end = end;
    }
    if (domain_count == 0 or state.current_porosity_fraction_by_domain.len != domain_count or
        inputs.initial_porosity_fraction_by_domain.len != domain_count)
        return error.RootPorositySweepDimensionMismatch;

    for (0..inputs.plant_count) |plant| {
        const start = inputs.biological_domain_offsets_by_plant[plant];
        const end = inputs.biological_domain_offsets_by_plant[plant + 1];
        for (start..end) |domain| {
            _ = try porosity.adapt(
                state.current_porosity_fraction_by_domain[domain],
                inputs.initial_porosity_fraction_by_domain[domain],
                inputs.oxygen_satisfaction_fraction_by_plant[plant],
                inputs.biological_timestep_h,
                inputs.parameters,
            );
        }
    }

    for (0..inputs.plant_count) |plant| {
        const start = inputs.biological_domain_offsets_by_plant[plant];
        const end = inputs.biological_domain_offsets_by_plant[plant + 1];
        for (start..end) |domain| {
            state.current_porosity_fraction_by_domain[domain] = try porosity.adapt(
                state.current_porosity_fraction_by_domain[domain],
                inputs.initial_porosity_fraction_by_domain[domain],
                inputs.oxygen_satisfaction_fraction_by_plant[plant],
                inputs.biological_timestep_h,
                inputs.parameters,
            );
        }
    }
}

test "GROSUB PORT preserves runtime plant and biological-domain topology" {
    var current = [_]f64{ 0.20, 0.30, 0.40, 0.50, 0.60 };
    try apply(.{ .current_porosity_fraction_by_domain = &current }, .{
        .plant_count = 2,
        .biological_domain_offsets_by_plant = &.{ 0, 2, 5 },
        .initial_porosity_fraction_by_domain = &.{ 0.20, 0.10, 0.40, 0.30, 0.20 },
        .oxygen_satisfaction_fraction_by_plant = &.{ 0.0, 1.0 },
        .biological_timestep_h = 1.0,
        .parameters = porosity.compatibilityParameters(),
    });

    try std.testing.expectApproxEqAbs(@as(f64, 0.220), current[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.308), current[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.400), current[2], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.498), current[3], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.596), current[4], 1e-15);
}

test "GROSUB PORT sweep rejects malformed runtime domain offsets atomically" {
    var current = [_]f64{ 0.2, 0.3, 0.4 };
    const before = current;
    try std.testing.expectError(error.InvalidRootPorosityDomainOffsets, apply(
        .{ .current_porosity_fraction_by_domain = &current },
        .{
            .plant_count = 2,
            .biological_domain_offsets_by_plant = &.{ 0, 2, 1 },
            .initial_porosity_fraction_by_domain = &.{ 0.2, 0.3, 0.4 },
            .oxygen_satisfaction_fraction_by_plant = &.{ 0.0, 1.0 },
            .biological_timestep_h = 1.0,
            .parameters = porosity.compatibilityParameters(),
        },
    ));
    try std.testing.expectEqualDeep(before, current);
}

test "GROSUB PORT sweep rolls back on invalid late biological domain" {
    var current = [_]f64{ 0.2, 0.3, 0.4, std.math.nan(f64) };
    const before = current;
    try std.testing.expectError(error.NonFiniteRootPorosityInput, apply(
        .{ .current_porosity_fraction_by_domain = &current },
        .{
            .plant_count = 2,
            .biological_domain_offsets_by_plant = &.{ 0, 1, 4 },
            .initial_porosity_fraction_by_domain = &.{ 0.2, 0.3, 0.4, 0.5 },
            .oxygen_satisfaction_fraction_by_plant = &.{ 0.0, 0.5 },
            .biological_timestep_h = 1.0,
            .parameters = porosity.compatibilityParameters(),
        },
    ));
    try std.testing.expectEqualDeep(before[0..3], current[0..3]);
    try std.testing.expect(std.math.isNan(current[3]));
}

test "GROSUB PORT sweep is invariant to plant decomposition" {
    const initial = [_]f64{ 0.20, 0.31, 0.42, 0.53, 0.64 };
    const oxygen = [_]f64{ 0.15, 0.85 };
    var whole = initial;
    var split = initial;
    const parameters = porosity.compatibilityParameters();

    try apply(.{ .current_porosity_fraction_by_domain = &whole }, .{
        .plant_count = 2,
        .biological_domain_offsets_by_plant = &.{ 0, 2, 5 },
        .initial_porosity_fraction_by_domain = &.{ 0.18, 0.27, 0.39, 0.48, 0.57 },
        .oxygen_satisfaction_fraction_by_plant = &oxygen,
        .biological_timestep_h = 0.5,
        .parameters = parameters,
    });
    try apply(.{ .current_porosity_fraction_by_domain = split[0..2] }, .{
        .plant_count = 1,
        .biological_domain_offsets_by_plant = &.{ 0, 2 },
        .initial_porosity_fraction_by_domain = &.{ 0.18, 0.27 },
        .oxygen_satisfaction_fraction_by_plant = oxygen[0..1],
        .biological_timestep_h = 0.5,
        .parameters = parameters,
    });
    try apply(.{ .current_porosity_fraction_by_domain = split[2..5] }, .{
        .plant_count = 1,
        .biological_domain_offsets_by_plant = &.{ 0, 3 },
        .initial_porosity_fraction_by_domain = &.{ 0.39, 0.48, 0.57 },
        .oxygen_satisfaction_fraction_by_plant = oxygen[1..2],
        .biological_timestep_h = 0.5,
        .parameters = parameters,
    });

    try std.testing.expectEqualSlices(f64, &whole, &split);
}

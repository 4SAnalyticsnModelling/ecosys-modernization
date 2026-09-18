const std = @import("std");

/// One conservation identity in one quantity's native units:
/// delta storage = external inputs - external outputs + internal production
///                 - internal consumption.
///
/// Callers choose the scope (cell, layer/column, process, domain, hour, or
/// accumulated interval) by constructing one transaction per scope. Keeping
/// this unit-free prevents water, energy, and elemental tolerances from being
/// collapsed into one universal threshold.
pub const Transaction = struct {
    storage_before: f64,
    storage_after: f64,
    external_inputs: f64 = 0,
    external_outputs: f64 = 0,
    internal_production: f64 = 0,
    internal_consumption: f64 = 0,
};

pub const Tolerance = struct {
    absolute: f64,
    relative: f64,
    /// Provenance-derived forward-error bound from arithmetic performed
    /// upstream of this final closure evaluation. It is reported separately
    /// from, and never changes, the configured physical tolerance.
    upstream_arithmetic_roundoff_allowance: f64 = 0,

    pub fn validate(self: Tolerance) !void {
        if (!std.math.isFinite(self.absolute) or self.absolute < 0 or
            !std.math.isFinite(self.relative) or self.relative < 0 or
            !std.math.isFinite(self.upstream_arithmetic_roundoff_allowance) or
            self.upstream_arithmetic_roundoff_allowance < 0)
            return error.InvalidConservationTolerance;
    }
};

pub const Closure = struct {
    residual: f64,
    absolute: f64,
    normalization_scale: f64,
    normalized_relative: f64,
    /// Configured physical absolute-plus-relative limit. This deliberately
    /// excludes floating-point representation error so diagnostics continue
    /// to report the scientific acceptance criterion unchanged.
    acceptance_limit: f64,
    /// Forward-error bound for evaluating this six-term closure identity in
    /// binary64. This is not a physical tolerance.
    arithmetic_roundoff_allowance: f64,
    effective_acceptance_limit: f64,
    physical_accepted: bool,
    accepted: bool,
};

// `residual` is the source-ordered sum
//   after - before - inputs + outputs - production + consumption.
// Six signed addends require at most five binary additions/subtractions.
const closure_arithmetic_operation_count: usize = 5;

fn closureArithmeticRoundoffAllowance(
    transaction: Transaction,
    throughput: f64,
) !f64 {
    const operation_count: f64 = @floatFromInt(closure_arithmetic_operation_count);
    const scaled_epsilon = operation_count * std.math.floatEps(f64);
    if (scaled_epsilon >= 1) return error.NonFiniteConservationClosure;
    // Higham's gamma_n bound applied to the sum of absolute addends. The two
    // storage terms are bounded by twice their maximum standing magnitude;
    // all four directional activity terms sum exactly to `throughput` here.
    const standing_storage = @max(
        @abs(transaction.storage_before),
        @abs(transaction.storage_after),
    );
    const addend_magnitude_bound = 2 * standing_storage + throughput;
    const allowance = scaled_epsilon / (1 - scaled_epsilon) *
        addend_magnitude_bound;
    if (!std.math.isFinite(addend_magnitude_bound) or
        !std.math.isFinite(allowance))
        return error.NonFiniteConservationClosure;
    return allowance;
}

/// Evaluate one scope with a scaled absolute-plus-relative criterion. The
/// normalization uses activity during this interval, not the potentially huge
/// standing stock: a small hourly leak cannot disappear behind a large SOM,
/// mineral, water, or energy inventory.
pub fn evaluate(transaction: Transaction, tolerance: Tolerance) !Closure {
    try tolerance.validate();
    inline for (std.meta.fields(Transaction)) |field| {
        const value = @field(transaction, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteConservationTerm;
    }
    if (transaction.external_inputs < 0 or transaction.external_outputs < 0 or
        transaction.internal_production < 0 or transaction.internal_consumption < 0)
        return error.NegativeDirectionalConservationTerm;

    const delta_storage = transaction.storage_after - transaction.storage_before;
    const expected_delta = transaction.external_inputs - transaction.external_outputs +
        transaction.internal_production - transaction.internal_consumption;
    const residual = delta_storage - expected_delta;
    if (!std.math.isFinite(delta_storage) or !std.math.isFinite(expected_delta) or
        !std.math.isFinite(residual))
        return error.NonFiniteConservationClosure;

    const throughput = transaction.external_inputs + transaction.external_outputs +
        transaction.internal_production + transaction.internal_consumption;
    const scale = @max(@abs(delta_storage), throughput);
    const normalized = if (scale > 0) @abs(residual) / scale else 0;
    const limit = tolerance.absolute + tolerance.relative * scale;
    const arithmetic_roundoff_allowance =
        try closureArithmeticRoundoffAllowance(transaction, throughput) +
        tolerance.upstream_arithmetic_roundoff_allowance;
    const effective_limit = limit + arithmetic_roundoff_allowance;
    if (!std.math.isFinite(scale) or !std.math.isFinite(normalized) or
        !std.math.isFinite(limit) or !std.math.isFinite(effective_limit))
        return error.NonFiniteConservationClosure;
    return .{
        .residual = residual,
        .absolute = @abs(residual),
        .normalization_scale = scale,
        .normalized_relative = normalized,
        .acceptance_limit = limit,
        .arithmetic_roundoff_allowance = arithmetic_roundoff_allowance,
        .effective_acceptance_limit = effective_limit,
        .physical_accepted = @abs(residual) <= limit,
        .accepted = @abs(residual) <= effective_limit,
    };
}

pub const Summary = struct {
    aggregate: Closure,
    maximum_local_absolute: f64,
    maximum_local_normalized_relative: f64,
    failing_local_scopes: usize,
};

/// Checks every supplied local scope before reducing the domain. The aggregate
/// is diagnostic only: `failing_local_scopes` remains authoritative so equal
/// and opposite cell/layer/process errors cannot cancel into a false pass.
pub fn summarize(
    transactions: []const Transaction,
    tolerance: Tolerance,
) !Summary {
    if (transactions.len == 0) return error.EmptyConservationScope;
    var total = Transaction{ .storage_before = 0, .storage_after = 0 };
    var maximum_absolute: f64 = 0;
    var maximum_relative: f64 = 0;
    var failures: usize = 0;
    for (transactions) |transaction| {
        const closure = try evaluate(transaction, tolerance);
        maximum_absolute = @max(maximum_absolute, closure.absolute);
        maximum_relative = @max(maximum_relative, closure.normalized_relative);
        failures += @intFromBool(!closure.accepted);
        inline for (std.meta.fields(Transaction)) |field| {
            const next = @field(total, field.name) + @field(transaction, field.name);
            if (!std.math.isFinite(next)) return error.ConservationScopeOverflow;
            @field(total, field.name) = next;
        }
    }
    return .{
        .aggregate = try evaluate(total, tolerance),
        .maximum_local_absolute = maximum_absolute,
        .maximum_local_normalized_relative = maximum_relative,
        .failing_local_scopes = failures,
    };
}

/// Donor/recipient check after an explicit unit or stoichiometric conversion.
/// `recipient_units_per_donor_unit` must be positive and finite.
pub fn evaluateTransfer(
    donor_loss: f64,
    recipient_gain: f64,
    recipient_units_per_donor_unit: f64,
    tolerance: Tolerance,
) !Closure {
    inline for (.{ donor_loss, recipient_gain }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidInternalTransfer;
    if (!std.math.isFinite(recipient_units_per_donor_unit) or
        recipient_units_per_donor_unit <= 0)
        return error.InvalidStoichiometricConversion;
    const converted_donor = donor_loss * recipient_units_per_donor_unit;
    if (!std.math.isFinite(converted_donor))
        return error.NonFiniteConservationClosure;
    try tolerance.validate();
    const residual = recipient_gain - converted_donor;
    // A transfer's scale is the material actually exchanged, not its
    // mismatch. Treating the converted donor as `storage_before` made
    // `evaluate` see only delta-storage activity, so every non-zero mismatch
    // normalized to one even for a billion-unit transfer.
    const scale = @max(converted_donor, recipient_gain);
    const normalized = if (scale > 0) @abs(residual) / scale else 0;
    const limit = tolerance.absolute + tolerance.relative * scale;
    if (!std.math.isFinite(residual) or !std.math.isFinite(scale) or
        !std.math.isFinite(normalized) or !std.math.isFinite(limit))
        return error.NonFiniteConservationClosure;
    return .{
        .residual = residual,
        .absolute = @abs(residual),
        .normalization_scale = scale,
        .normalized_relative = normalized,
        .acceptance_limit = limit,
        .arithmetic_roundoff_allowance = 0,
        .effective_acceptance_limit = limit,
        .physical_accepted = @abs(residual) <= limit,
        .accepted = @abs(residual) <= limit,
    };
}

test "scaled absolute plus relative closure uses interval activity" {
    const closure = try evaluate(.{
        .storage_before = 1.0e12,
        .storage_after = 1.0e12 + 100.001,
        .external_inputs = 100,
    }, .{ .absolute = 1.0e-4, .relative = 1.0e-5 });
    try std.testing.expect(closure.accepted);
    try std.testing.expectApproxEqAbs(@as(f64, 100), closure.normalization_scale, 0.01);
    try std.testing.expect(closure.normalized_relative < 1.1e-5);
}

test "local closure failures survive exact domain cancellation" {
    const summary = try summarize(&.{
        .{ .storage_before = 0, .storage_after = 1 },
        .{ .storage_before = 1, .storage_after = 0 },
    }, .{ .absolute = 1.0e-6, .relative = 1.0e-8 });
    try std.testing.expect(summary.aggregate.accepted);
    try std.testing.expectEqual(@as(f64, 0), summary.aggregate.residual);
    try std.testing.expectEqual(@as(usize, 2), summary.failing_local_scopes);
    try std.testing.expectEqual(@as(f64, 1), summary.maximum_local_absolute);
}

test "donor recipient transfer applies unit conversion before closure" {
    const exact = try evaluateTransfer(2, 6, 3, .{
        .absolute = 1.0e-12,
        .relative = 1.0e-10,
    });
    try std.testing.expect(exact.accepted);
    const wrong_stoichiometry = try evaluateTransfer(2, 5.9, 3, .{
        .absolute = 1.0e-12,
        .relative = 1.0e-10,
    });
    try std.testing.expect(!wrong_stoichiometry.accepted);

    const large_transfer = try evaluateTransfer(1.0e9, 1.0e9 + 1, 1, .{
        .absolute = 0,
        .relative = 2.0e-9,
    });
    try std.testing.expect(large_transfer.accepted);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0e-9), large_transfer.normalized_relative, 2.0e-18);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0e9 + 1), large_transfer.normalization_scale, 0);
}

test "failed scoped validation is read only" {
    const transactions = [_]Transaction{
        .{ .storage_before = 1, .storage_after = 2, .external_inputs = 1 },
        .{ .storage_before = 2, .storage_after = 3, .external_outputs = -1 },
    };
    const before = transactions;
    try std.testing.expectError(
        error.NegativeDirectionalConservationTerm,
        summarize(&transactions, .{ .absolute = 1e-6, .relative = 1e-8 }),
    );
    try std.testing.expectEqualDeep(before, transactions);
}

test "zero activity standing-stock reconstruction accepts only arithmetic roundoff" {
    // Equivalent texture inventories accumulated in different valid orders
    // can land two adjacent representable values apart. Use explicit adjacent
    // encodings so optimizer constant reassociation cannot erase the fixture.
    const before: f64 = 1;
    const after: f64 = @bitCast(@as(u64, @bitCast(before)) + 2);
    const closure = try evaluate(.{
        .storage_before = before,
        .storage_after = after,
    }, .{ .absolute = 0, .relative = 1.0e-9 });
    try std.testing.expect(closure.absolute > closure.acceptance_limit);
    try std.testing.expect(closure.absolute <= closure.arithmetic_roundoff_allowance);
    try std.testing.expectEqual(
        closure.acceptance_limit + closure.arithmetic_roundoff_allowance,
        closure.effective_acceptance_limit,
    );
    try std.testing.expect(!closure.physical_accepted);
    try std.testing.expect(closure.accepted);
}

test "zero activity leakage above arithmetic bound remains rejected" {
    const before = (0.1 + 0.2) + 0.3;
    const closure = try evaluate(.{
        .storage_before = before,
        .storage_after = before + 1.0e-12,
    }, .{ .absolute = 0, .relative = 1.0e-9 });
    try std.testing.expect(closure.absolute > closure.arithmetic_roundoff_allowance);
    try std.testing.expect(closure.absolute > closure.effective_acceptance_limit);
    try std.testing.expect(!closure.physical_accepted);
    try std.testing.expect(!closure.accepted);
}

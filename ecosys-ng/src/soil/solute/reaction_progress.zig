//! Work policy for undamped source residuals scaled by fixed entry inventories.
//! Fixed scales avoid mistaking a shrinking trace pool for physical divergence.
//! Progress ratios limit wasted iterations; they never authorize acceptance.
const std = @import("std");

pub const BalanceQuality = struct { maximum: f64 = 0, rms: f64 = 0 };

/// Fractional undamped source changes on fixed entry inventory scales.
/// Numerical solver tolerances have no role in this work-policy measure.
pub fn balanceQuality(residual: []const f64, inventories: []const f64) !BalanceQuality {
    if (residual.len == 0 or residual.len != inventories.len) return error.InvalidReactionProgressInventory;
    var result: BalanceQuality = .{};
    for (residual, inventories) |change, inventory| {
        if (!std.math.isFinite(change) or !std.math.isFinite(inventory) or inventory < 0) return error.InvalidReactionProgressInventory;
        const ratio = if (change == 0) 0 else if (inventory > 0) @abs(change) / inventory else std.math.inf(f64);
        result.maximum = @max(result.maximum, ratio);
        result.rms = std.math.hypot(result.rms, ratio);
    }
    result.rms /= @sqrt(@as(f64, @floatFromInt(residual.len)));
    return result;
}

pub const Decision = enum { proceed, anderson, stop };

pub const Monitor = struct {
    anchor_maximum: f64 = std.math.inf(f64),
    anchor_rms: f64 = std.math.inf(f64),
    stale_iterations: u8 = 0,
    recovery_seen: bool = false,

    pub fn observe(self: *Monitor, maximum: f64, rms: f64, used_anderson: bool) Decision {
        if (!std.math.isFinite(maximum) or !std.math.isFinite(rms)) return .stop;
        // Use the existing solver's numerical progress resolution, not a
        // percentage target that could stop slow but resolvable chemistry.
        const resolution = std.math.sqrt(std.math.floatEps(f64));
        const maximum_floor = resolution * self.anchor_maximum;
        const rms_floor = resolution * self.anchor_rms;
        const progress = !std.math.isFinite(self.anchor_maximum) or
            self.anchor_maximum - maximum > maximum_floor or
            self.anchor_rms - rms > rms_floor;
        if (progress) {
            // Keep independent records. Replacing one record with a worse
            // value when the other improves can falsely credit oscillation.
            self.anchor_maximum = @min(self.anchor_maximum, maximum);
            self.anchor_rms = @min(self.anchor_rms, rms);
            self.stale_iterations = 0;
            self.recovery_seen = false;
            return .proceed;
        }
        self.stale_iterations +|= 1;
        self.recovery_seen = self.recovery_seen or used_anderson;
        if (self.stale_iterations < 4) return .proceed;
        return if (self.recovery_seen) .stop else .anderson;
    }
};

/// Detects a repeated bounded state at floating-point resolution. A repeated
/// maximum residual alone is insufficient evidence of a state oscillation.
pub fn repeatsState(current: []const f64, previous: []const f64) bool {
    if (current.len != previous.len) return false;
    for (current, previous) |a, b| {
        if (!std.math.isFinite(a) or !std.math.isFinite(b)) return false;
        if (@abs(a - b) > 64 * std.math.floatEps(f64) * @max(@abs(a), @abs(b))) return false;
    }
    return true;
}

//! WATSUB snow cover fraction, `watsub.f` lines 386--392 and 886--892.
//!
//! This is the single authoritative owner of the source `FSNW`/`FSNX` pair.
//! It exists because the expression had been open-coded five different ways
//! across `src/`, three of them wrong, and two of the wrong ones were the only
//! production-reachable copies. See
//! `docs/traceability/watsub_snow_cover_fraction_exponent_defect.md`.
//!
//! Source, verbatim (both occurrences are identical apart from the depth
//! carrier, `DPTHS` at 386 versus `DPTHS0` at 886):
//!
//! ```
//!       FSNW(NY,NX)=AMIN1(1.0,SQRT(DPTHS(NY,NX)/DPTHSX))
//!       IF(FSNW(NY,NX).LT.1.0)THEN
//!       FSNX(NY,NX)=AMAX1(1.0E-03,1.0-FSNW(NY,NX))
//!       FSNW(NY,NX)=1.0-FSNX(NY,NX)
//!       ELSE
//!       FSNX(NY,NX)=0.0
//!       ENDIF
//! ```
//!
//! Three properties are easy to lose and each is pinned by a test below.
//!
//!  1. The relation is a **square root** of the depth ratio, so cover rises
//!     steeply for thin snow. Squaring the ratio instead is not a small error:
//!     at one tenth of the full-cover depth the two forms differ by 18.5x, and
//!     at one fourteenth by 52.4x, always understating cover. Because
//!     `FSNW` multiplies snow-surface albedo, snow radiation, and snow-side
//!     vapour and heat exchange, understating it makes a thin snowpack behave
//!     almost like bare ground.
//!  2. `FSNX` is floored at `1.0e-3` and `FSNW` is then **recomputed as its
//!     complement**, so a partial pack never fully closes the snow-free path.
//!     That floor is what keeps the snow-free branch alive as a divisor and as
//!     a bare-soil exchange route. Clamping `FSNW` to `[0,1]` and taking
//!     `1 - FSNW` skips it, letting the snow-free fraction reach exactly zero.
//!  3. The complement is exact by construction: `FSNW + FSNX == 1` always,
//!     including at and above full cover, where `FSNX` is exactly zero.
//!
//! `DPTHSX` is a runtime runscript control (`snow_full_cover_depth_m`), never a
//! compile-time constant, per `MIGRATION.md`. The source `PARAMETER` value is
//! `0.05`; Ottawa supplies its own.

const std = @import("std");

/// The source `FSNW`/`FSNX` pair for one cell. They always sum to one.
pub const Cover = struct {
    /// `FSNW`, the snow-covered fraction.
    snow_fraction: f64,
    /// `FSNX`, the snow-free fraction. Floored at `minimum_snow_free_fraction`
    /// whenever cover is partial, and exactly zero at or above full cover.
    snow_free_fraction: f64,
};

/// `AMAX1(1.0E-03, ...)`, the source floor on the snow-free fraction.
pub const minimum_snow_free_fraction: f64 = 1.0e-3;

/// Evaluates `watsub.f` 386--392 for one cell.
///
/// `full_cover_depth_m` is the runtime `DPTHSX`; it must be positive, since the
/// source divides by it.
pub fn evaluate(snow_depth_m: f64, full_cover_depth_m: f64) !Cover {
    if (!std.math.isFinite(snow_depth_m) or !std.math.isFinite(full_cover_depth_m))
        return error.NonFiniteSnowCoverInput;
    if (snow_depth_m < 0 or full_cover_depth_m <= 0)
        return error.InvalidSnowCoverInput;

    // `AMIN1(1.0, SQRT(DPTHS/DPTHSX))`.
    var snow_fraction = @min(1.0, @sqrt(snow_depth_m / full_cover_depth_m));
    var snow_free_fraction: f64 = 0;
    if (snow_fraction < 1.0) {
        // `FSNX = AMAX1(1.0E-03, 1.0-FSNW)` then `FSNW = 1.0-FSNX`. The order
        // matters: the floor is applied to the snow-FREE fraction, and the
        // covered fraction is then its exact complement.
        snow_free_fraction = @max(minimum_snow_free_fraction, 1.0 - snow_fraction);
        snow_fraction = 1.0 - snow_free_fraction;
    }
    if (!std.math.isFinite(snow_fraction) or !std.math.isFinite(snow_free_fraction))
        return error.NonFiniteSnowCoverResult;
    return .{ .snow_fraction = snow_fraction, .snow_free_fraction = snow_free_fraction };
}

test "cover follows the source square root of the depth ratio" {
    const depth = 0.0175; // one fourth of the full-cover depth
    const cover = try evaluate(depth, 0.07);
    // sqrt(0.25) = 0.5 exactly, and the 1e-3 floor does not bind there.
    try std.testing.expectApproxEqRel(@as(f64, 0.5), cover.snow_fraction, 1e-15);
    // The squared form would have produced 0.0625, an 8x understatement.
    try std.testing.expect(cover.snow_fraction > 0.0625 * 7);
}

test "snow and snow-free fractions are exact complements at every depth" {
    for ([_]f64{ 0, 1e-9, 0.001, 0.005, 0.0175, 0.035, 0.05, 0.069, 0.07, 0.5, 100 }) |depth| {
        const cover = try evaluate(depth, 0.07);
        try std.testing.expectApproxEqAbs(@as(f64, 1), cover.snow_fraction + cover.snow_free_fraction, 1e-15);
        try std.testing.expect(cover.snow_fraction >= 0 and cover.snow_fraction <= 1);
        try std.testing.expect(cover.snow_free_fraction >= 0 and cover.snow_free_fraction <= 1);
    }
}

test "a partial pack retains the source floor on the snow-free fraction" {
    // Just below full cover the unfloored complement is far under 1e-3, so the
    // floor binds and the snow-free exchange path stays open.
    const cover = try evaluate(0.06999999, 0.07);
    try std.testing.expect(cover.snow_free_fraction >= minimum_snow_free_fraction);
    try std.testing.expect(cover.snow_fraction < 1.0);
    // Clamping FSNW instead would have produced a snow_free_fraction of ~7e-8,
    // effectively closing the bare-ground route.
    try std.testing.expect(cover.snow_free_fraction > 1e-7 * 100);
}

test "full cover closes the snow-free fraction exactly" {
    for ([_]f64{ 0.07, 0.0700001, 1.0 }) |depth| {
        const cover = try evaluate(depth, 0.07);
        try std.testing.expectEqual(@as(f64, 1), cover.snow_fraction);
        try std.testing.expectEqual(@as(f64, 0), cover.snow_free_fraction);
    }
}

test "bare ground is fully snow free" {
    const cover = try evaluate(0, 0.07);
    try std.testing.expectEqual(@as(f64, 0), cover.snow_fraction);
    try std.testing.expectEqual(@as(f64, 1), cover.snow_free_fraction);
}

test "cover increases monotonically with depth" {
    var previous: f64 = -1;
    var depth: f64 = 0;
    while (depth <= 0.07) : (depth += 0.0005) {
        const cover = try evaluate(depth, 0.07);
        try std.testing.expect(cover.snow_fraction >= previous);
        previous = cover.snow_fraction;
    }
}

test "the full-cover depth is a runtime control, not a constant" {
    // The same depth gives different cover under different runscript controls,
    // and a shallower full-cover depth always gives at least as much cover.
    const shallow = try evaluate(0.02, 0.05);
    const deep = try evaluate(0.02, 0.20);
    try std.testing.expect(shallow.snow_fraction > deep.snow_fraction);
    // The source PARAMETER value, for reference only.
    const source_default = try evaluate(0.05, 0.05);
    try std.testing.expectEqual(@as(f64, 1), source_default.snow_fraction);
}

test "snow transport modules cannot reintroduce a local linear cover law" {
    inline for (.{
        @embedFile("snow_heat_conduction.zig"),
        @embedFile("snow_vapor_diffusion.zig"),
    }) |source| {
        try std.testing.expect(std.mem.indexOf(u8, source, "snow_cover_fraction.evaluate") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "clamp(depth_m / options.full_snow_cover_depth_m") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "cumulative_depth_m[base + state.layer_capacity - 1] / options.full_snow_cover_depth_m") == null);
    }
}

test "invalid inputs are rejected before producing a fraction" {
    try std.testing.expectError(error.NonFiniteSnowCoverInput, evaluate(std.math.nan(f64), 0.07));
    try std.testing.expectError(error.NonFiniteSnowCoverInput, evaluate(0.01, std.math.inf(f64)));
    try std.testing.expectError(error.InvalidSnowCoverInput, evaluate(-0.01, 0.07));
    // The source divides by DPTHSX, so a zero or negative control is invalid.
    try std.testing.expectError(error.InvalidSnowCoverInput, evaluate(0.01, 0));
    try std.testing.expectError(error.InvalidSnowCoverInput, evaluate(0.01, -0.07));
}

//! Integrated (Kirchhoff) face conductance for the Richards faces.
//!
//! `PR-KIRCHHOFF-DESIGN`, design note
//! `docs/traceability/dry_face_conductance_collapse_kirchhoff_design.md`.
//!
//! ## Why this file exists
//!
//! `flux.zig:57-66` builds a face conductance as the path-length-weighted
//! harmonic mean of the two endpoint conductivities. A harmonic mean is bounded
//! above by twice its smaller argument, so the dry cell alone dictates the
//! face. Mualem-van Genuchten `K` falls by orders of magnitude per unit of
//! saturation near the dry end, so the face closes and a drying layer becomes
//! an absorbing state: once dry it stops receiving water and can never rewet.
//!
//! That is wrong physics, not conservative numerics. The Darcy-Buckingham flux
//! integrated between the two cell states is
//!
//!     q = -(1/L) * integral of K(psi) dpsi from psi_dst to psi_src
//!
//! As the dry cell dries, `K -> 0` but `|psi_src - psi_dst| -> infinity` at a
//! compensating rate and the product converges to a finite limit. The physical
//! flux does not vanish; the harmonic-mean discretisation does.
//!
//! ## What is computed here
//!
//! The **interval-averaged** conductivity of one cell's own curve over the
//! matric-potential interval spanned by the face,
//!
//!     K_bar = (1 / (psi_a - psi_b)) * integral of K(psi) dpsi from psi_b to psi_a
//!
//! which is the mean value theorem's `K` at some interior state rather than the
//! endpoint value. Substituting `K_bar` for each endpoint conductivity in the
//! existing path-length-weighted harmonic form gives the design note's
//! heterogeneous-interface policy for free: continuity of `psi` (not of `Se`)
//! at the interface, with the integral split at the interface state and the two
//! integral-averaged conductances combined in series by path length.
//!
//! Properties, each of which is a test below:
//!
//! 1. Exact for a homogeneous face at any degree of dryness (`KIRCH-F2`).
//! 2. Never zero unless `K == 0` on the whole interval (`KIRCH-F1`).
//! 3. Symmetric under swapping the endpoints (`KIRCH-F4`).
//! 4. Reduces to the endpoint value as the states converge (`KIRCH-F3`), so
//!    wet-profile behaviour is unchanged to second order.
//!
//! The averaging uses the **matric** interval, because `K` is a function of
//! matric potential alone, while the driving force in `flux.zig` remains the
//! full total-potential difference including gravity and osmotic terms. A face
//! driven purely by gravity between two cells at the same matric state
//! therefore keeps exactly its present conductance.
//!
//! No calibration parameter is added. Everything here comes from the
//! constitutive curve already in `retention.zig`.

const std = @import("std");
const retention = @import("retention.zig");

/// Heads closer to saturation than this are treated as the saturated end.
/// Only needed because the quadrature runs in `ln(-h)`, which is undefined at
/// `h == 0`. The neglected sliver is `K <= Ks` over `1e-12 m` of head.
const saturated_head_epsilon_m: f64 = 1.0e-12;

/// Relative width below which the interval is treated as degenerate and the
/// endpoint conductivity is returned. This is the removable singularity of
/// `0/0` in the quotient, whose limit is `K` at the common state.
const degenerate_interval_relative_width: f64 = 1.0e-9;

/// Eight-point Gauss-Legendre nodes and weights on [-1, 1]. Exact for
/// polynomials of degree 15, which is far more than the smoothness of the
/// integrand in the log-head variable requires.
const gauss_nodes = [8]f64{
    -0.9602898564975363,
    -0.7966664774136267,
    -0.5255324099163290,
    -0.1834346424956498,
    0.1834346424956498,
    0.5255324099163290,
    0.7966664774136267,
    0.9602898564975363,
};
const gauss_weights = [8]f64{
    0.1012285362903763,
    0.2223810344533745,
    0.3137066458778873,
    0.3626837833783620,
    0.3626837833783620,
    0.3137066458778873,
    0.2223810344533745,
    0.1012285362903763,
};

/// Subintervals per decade of head spanned by the face. The integrand spans
/// many decades, so the subdivision is log-spaced. One eight-point panel per
/// decade remains below the independently refined `1e-6` relative-error
/// bound measured by `intervalAveragedConductivityQuadratureError`.
const subintervals_per_decade: f64 = 1.0;
const maximum_subintervals: usize = 64;

/// Solve-local exact memoization for the constitutive quadrature below.
///
/// A dense Richards Jacobian evaluates one full residual for each coordinate
/// perturbation. Most faces are unchanged by any one perturbation, but without
/// this cache their identical log-space Gauss-Legendre integrals are repeated
/// for every column. Entries are keyed by every constitutive parameter and by
/// the canonical head interval. A direct-mapped collision is deliberately a
/// miss: it can cost time but can never substitute a result from another
/// physical state.
pub const Cache = struct {
    const capacity: usize = 4096;
    comptime {
        std.debug.assert(std.math.isPowerOfTwo(capacity));
    }

    const Entry = struct {
        parameters: retention.MualemVanGenuchtenParameters,
        low_head_m: f64,
        high_head_m: f64,
        conductivity_m_per_h: f64,
    };

    entries: [capacity]?Entry = [_]?Entry{null} ** capacity,
    hits: usize = 0,
    misses: usize = 0,
    collisions: usize = 0,

    pub fn getOrCompute(
        self: *Cache,
        parameters: retention.MualemVanGenuchtenParameters,
        head_a_m: f64,
        head_b_m: f64,
    ) !f64 {
        try parameters.validate();
        return self.getOrComputeAssumeValid(parameters, head_a_m, head_b_m);
    }

    /// Lookup repeatedly after the caller has validated this parameter set.
    pub fn getOrComputeAssumeValid(
        self: *Cache,
        parameters: retention.MualemVanGenuchtenParameters,
        head_a_m: f64,
        head_b_m: f64,
    ) !f64 {
        if (!std.math.isFinite(head_a_m) or !std.math.isFinite(head_b_m))
            return error.NonFinitePressureHead;

        const high_head_m = normalizeZero(@min(0.0, @max(head_a_m, head_b_m)));
        const low_head_m = normalizeZero(@min(@min(head_a_m, head_b_m), high_head_m));
        const index = hashKey(parameters, low_head_m, high_head_m) & (capacity - 1);
        if (self.entries[index]) |entry| {
            if (parametersEqual(entry.parameters, parameters) and
                entry.low_head_m == low_head_m and
                entry.high_head_m == high_head_m)
            {
                self.hits += 1;
                return entry.conductivity_m_per_h;
            }
            self.collisions += 1;
        }

        self.misses += 1;
        const conductivity_m_per_h = try intervalAveragedConductivityMPerHAssumeValid(
            parameters,
            head_a_m,
            head_b_m,
        );
        self.entries[index] = .{
            .parameters = parameters,
            .low_head_m = low_head_m,
            .high_head_m = high_head_m,
            .conductivity_m_per_h = conductivity_m_per_h,
        };
        return conductivity_m_per_h;
    }

    fn normalizeZero(value: f64) f64 {
        return if (value == 0) 0 else value;
    }

    fn parametersEqual(
        left: retention.MualemVanGenuchtenParameters,
        right: retention.MualemVanGenuchtenParameters,
    ) bool {
        inline for (@typeInfo(retention.MualemVanGenuchtenParameters).@"struct".fields) |field| {
            if (@field(left, field.name) != @field(right, field.name)) return false;
        }
        return true;
    }

    fn hashKey(
        parameters: retention.MualemVanGenuchtenParameters,
        low_head_m: f64,
        high_head_m: f64,
    ) usize {
        var hash: u64 = 0x9e3779b97f4a7c15;
        inline for (@typeInfo(retention.MualemVanGenuchtenParameters).@"struct".fields) |field|
            hash = mix(hash, floatBits(@field(parameters, field.name)));
        hash = mix(hash, floatBits(low_head_m));
        hash = mix(hash, floatBits(high_head_m));
        return @intCast(hash);
    }

    fn floatBits(value: f64) u64 {
        return @bitCast(normalizeZero(value));
    }

    fn mix(seed: u64, value: u64) u64 {
        var mixed = value +% 0x9e3779b97f4a7c15 +% (seed << 6) +% (seed >> 2);
        mixed ^= mixed >> 30;
        mixed *%= 0xbf58476d1ce4e5b9;
        mixed ^= mixed >> 27;
        mixed *%= 0x94d049bb133111eb;
        return seed ^ (mixed ^ (mixed >> 31));
    }
};

/// `integral of K dh` over `[low_head_m, high_head_m]`, both non-positive, with
/// `low <= high`. Units: `m2 h-1` when `K` is in `m h-1`.
fn integrateConductivityOverHead(
    parameters: retention.MualemVanGenuchtenParameters,
    low_head_m: f64,
    high_head_m: f64,
) !f64 {
    return integrateConductivityOverHeadAtResolution(
        parameters,
        low_head_m,
        high_head_m,
        subintervals_per_decade,
        maximum_subintervals,
    );
}

fn integrateConductivityOverHeadAtResolution(
    parameters: retention.MualemVanGenuchtenParameters,
    low_head_m: f64,
    high_head_m: f64,
    panels_per_decade: f64,
    maximum_panels: usize,
) !f64 {
    std.debug.assert(low_head_m <= high_head_m);
    std.debug.assert(high_head_m <= 0);
    std.debug.assert(panels_per_decade > 0);
    std.debug.assert(maximum_panels > 0);

    // The sliver between `-epsilon` and saturation, integrated with the
    // saturated conductivity, which is an upper bound for `K` there.
    var total: f64 = 0;
    var upper_head_m = high_head_m;
    if (upper_head_m > -saturated_head_epsilon_m) {
        total += parameters.saturated_hydraulic_conductivity_m_per_h *
            (upper_head_m - -saturated_head_epsilon_m);
        upper_head_m = -saturated_head_epsilon_m;
    }
    if (low_head_m >= upper_head_m) return total;

    // Substitute `h = -exp(t)`, so `dh = -exp(t) dt` and the integral over
    // increasing `t` from the wet end to the dry end is positive.
    const wet_log = @log(-upper_head_m);
    const dry_log = @log(-low_head_m);
    const span = dry_log - wet_log;
    if (!std.math.isFinite(span) or span <= 0) return total;

    const requested: f64 = @ceil(span / std.math.ln10 * panels_per_decade);
    const subinterval_count: usize = @min(
        maximum_panels,
        @max(@as(usize, 1), @as(usize, @intFromFloat(requested))),
    );
    const step = span / @as(f64, @floatFromInt(subinterval_count));

    for (0..subinterval_count) |index| {
        const left = wet_log + step * @as(f64, @floatFromInt(index));
        const centre = left + step * 0.5;
        const half_width = step * 0.5;
        for (gauss_nodes, gauss_weights) |node, weight| {
            const t = centre + half_width * node;
            const suction_m = @exp(t);
            const head_m = -suction_m;
            const conductivity_m_per_h =
                try parameters.hydraulicConductivityMPerHAssumeValid(head_m);
            // `K dh` with `dh = exp(t) dt` in magnitude.
            total += weight * half_width * conductivity_m_per_h * suction_m;
        }
    }
    if (!std.math.isFinite(total) or total < 0)
        return error.NonFiniteKirchhoffPotential;
    return total;
}

/// Interval-averaged hydraulic conductivity of one curve over the head
/// interval spanned by a face, in `m h-1`.
///
/// This is the quantity that replaces the endpoint `K` in the face conductance.
/// Both heads are non-positive; the order of the two arguments does not matter,
/// which is `KIRCH-F4`.
pub fn intervalAveragedConductivityMPerH(
    parameters: retention.MualemVanGenuchtenParameters,
    head_a_m: f64,
    head_b_m: f64,
) !f64 {
    try parameters.validate();
    return intervalAveragedConductivityMPerHAssumeValid(
        parameters,
        head_a_m,
        head_b_m,
    );
}

/// Integrate repeatedly after the caller has validated this parameter set.
pub fn intervalAveragedConductivityMPerHAssumeValid(
    parameters: retention.MualemVanGenuchtenParameters,
    head_a_m: f64,
    head_b_m: f64,
) !f64 {
    if (!std.math.isFinite(head_a_m) or !std.math.isFinite(head_b_m))
        return error.NonFinitePressureHead;
    const high_head_m = @min(0.0, @max(head_a_m, head_b_m));
    const low_head_m = @min(@min(head_a_m, head_b_m), high_head_m);
    const width = high_head_m - low_head_m;

    // Removable singularity: a degenerate interval averages to the endpoint.
    const scale = @max(@abs(high_head_m), @abs(low_head_m));
    if (width <= degenerate_interval_relative_width * @max(scale, 1.0)) {
        return parameters.hydraulicConductivityMPerHAssumeValid(high_head_m);
    }

    const integral = try integrateConductivityOverHead(
        parameters,
        low_head_m,
        high_head_m,
    );
    const mean = integral / width;
    if (!std.math.isFinite(mean) or mean < 0)
        return error.NonFiniteKirchhoffPotential;
    // The mean of a positive function over an interval cannot exceed its
    // maximum, which on a monotone `K(h)` is the value at the wet endpoint.
    const wet_endpoint = try parameters.hydraulicConductivityMPerHAssumeValid(high_head_m);
    return @min(mean, wet_endpoint);
}

/// Maximum relative quadrature error over the interval, estimated by comparing
/// against a doubled subdivision. `PR0.3` requires a stated error bound; this
/// is the function that measures it, and `KIRCH-F2` asserts it.
pub fn intervalAveragedConductivityQuadratureError(
    parameters: retention.MualemVanGenuchtenParameters,
    head_a_m: f64,
    head_b_m: f64,
) !f64 {
    const coarse = try intervalAveragedConductivityMPerH(parameters, head_a_m, head_b_m);
    const high_head_m = @min(0.0, @max(head_a_m, head_b_m));
    const low_head_m = @min(@min(head_a_m, head_b_m), high_head_m);
    const width = high_head_m - low_head_m;
    if (width <= 0) return 0;
    const fine = try integrateConductivityOverHeadAtResolution(
        parameters,
        low_head_m,
        high_head_m,
        8 * subintervals_per_decade,
        4 * maximum_subintervals,
    ) / width;
    if (fine == 0) return 0;
    return @abs(coarse - fine) / fine;
}

// ---------------------------------------------------------------------------
// Falsifiers. Section 6 of the design note.
//
// Legacy `watsub.f` carried the harmonic mean, so legacy agreement is
// inadmissible as evidence here (`docs/agent_workflow.md:618-632`). These are
// new-behaviour tests.
// ---------------------------------------------------------------------------

const test_parameters = retention.MualemVanGenuchtenParameters{
    .residual_water_content_m3_per_m3 = 0.05,
    .saturated_water_content_m3_per_m3 = 0.45,
    .alpha_per_m = 3.6,
    .n = 1.56,
    .saturated_hydraulic_conductivity_m_per_h = 1.0,
    .pore_connectivity = 0.5,
};

test "solve-local cache returns exact quadrature for repeated and reversed intervals" {
    var cache: Cache = .{};
    const expected = try intervalAveragedConductivityMPerH(test_parameters, -1, -100);
    const first = try cache.getOrCompute(test_parameters, -1, -100);
    const repeated = try cache.getOrCompute(test_parameters, -1, -100);
    const reversed = try cache.getOrCompute(test_parameters, -100, -1);

    try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(first)));
    try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(repeated)));
    try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(reversed)));
    try std.testing.expectEqual(@as(usize, 1), cache.misses);
    try std.testing.expectEqual(@as(usize, 2), cache.hits);

    const changed_expected = try intervalAveragedConductivityMPerH(test_parameters, -1, -101);
    const changed = try cache.getOrCompute(test_parameters, -1, -101);
    try std.testing.expectEqual(
        @as(u64, @bitCast(changed_expected)),
        @as(u64, @bitCast(changed)),
    );
}

fn headAtEffectiveSaturation(
    parameters: retention.MualemVanGenuchtenParameters,
    effective_saturation: f64,
) !f64 {
    const water_content = parameters.residual_water_content_m3_per_m3 +
        effective_saturation *
            (parameters.saturated_water_content_m3_per_m3 -
                parameters.residual_water_content_m3_per_m3);
    return parameters.pressureHeadAtWaterContent(water_content);
}

/// The harmonic-mean face conductance that this module replaces, for equal
/// path lengths. Reproduced here so the falsifier can demonstrate the old
/// scheme failing rather than merely asserting that the new one passes.
fn legacyHarmonicFlux(
    source_conductivity: f64,
    destination_conductivity: f64,
    potential_difference: f64,
) f64 {
    const denominator = source_conductivity + destination_conductivity;
    const conductance = if (denominator > 0)
        2.0 * source_conductivity * destination_conductivity / denominator
    else
        0.0;
    return conductance * potential_difference;
}

fn kirchhoffFlux(
    parameters: retention.MualemVanGenuchtenParameters,
    wet_head_m: f64,
    dry_head_m: f64,
) !f64 {
    const averaged =
        try intervalAveragedConductivityMPerH(parameters, wet_head_m, dry_head_m);
    // Equal path lengths and a homogeneous face: both endpoints average to the
    // same value, so the harmonic mean of the two is that value.
    return legacyHarmonicFlux(averaged, averaged, wet_head_m - dry_head_m);
}

test "KIRCH-F1 the dry face does not close, and the old scheme does" {
    const wet_head_m = try headAtEffectiveSaturation(test_parameters, 0.80);
    const dry_saturations = [_]f64{ 0.50, 0.30, 0.20, 0.12, 0.08, 0.05 };

    var previous_legacy: f64 = std.math.inf(f64);
    var kirchhoff_values: [dry_saturations.len]f64 = undefined;

    for (dry_saturations, 0..) |dry_saturation, index| {
        const dry_head_m = try headAtEffectiveSaturation(test_parameters, dry_saturation);
        const wet_conductivity =
            try test_parameters.hydraulicConductivityMPerH(wet_head_m);
        const dry_conductivity =
            try test_parameters.hydraulicConductivityMPerH(dry_head_m);

        const legacy = legacyHarmonicFlux(
            wet_conductivity,
            dry_conductivity,
            wet_head_m - dry_head_m,
        );
        // The falsifier of the old scheme: its flux decays monotonically
        // towards zero as the neighbour dries. A patch that cannot show this
        // has not shown it fixed anything.
        try std.testing.expect(legacy < previous_legacy);
        previous_legacy = legacy;

        kirchhoff_values[index] = try kirchhoffFlux(
            test_parameters,
            wet_head_m,
            dry_head_m,
        );
    }

    // The old scheme has collapsed by orders of magnitude across the sweep.
    const first_legacy = legacyHarmonicFlux(
        try test_parameters.hydraulicConductivityMPerH(wet_head_m),
        try test_parameters.hydraulicConductivityMPerH(
            try headAtEffectiveSaturation(test_parameters, 0.50),
        ),
        wet_head_m - try headAtEffectiveSaturation(test_parameters, 0.50),
    );
    try std.testing.expect(previous_legacy < first_legacy * 1.0e-3);

    // The new scheme converges to a finite non-zero limit. Compare the driest
    // three, which must agree to a few parts in a thousand.
    const last = kirchhoff_values[kirchhoff_values.len - 1];
    try std.testing.expect(last > 0);
    for (kirchhoff_values[kirchhoff_values.len - 3 ..]) |value| {
        try std.testing.expect(@abs(value - last) <= 1.0e-3 * last);
    }
    // And it is not merely flat but genuinely larger than the collapsed
    // harmonic flux by the order the design note measured.
    try std.testing.expect(last > previous_legacy * 1.0e3);
}

test "KIRCH-F2 exactness against an independently refined quadrature" {
    const heads = [_][2]f64{
        .{ 0.80, 0.50 },
        .{ 0.80, 0.20 },
        .{ 0.80, 0.05 },
        .{ 0.95, 0.02 },
    };
    for (heads) |pair| {
        const a = try headAtEffectiveSaturation(test_parameters, pair[0]);
        const b = try headAtEffectiveSaturation(test_parameters, pair[1]);
        const relative_error =
            try intervalAveragedConductivityQuadratureError(test_parameters, a, b);
        // Stated error bound for the shipped quadrature.
        try std.testing.expect(relative_error < 1.0e-6);
    }
}

test "KIRCH-F2 error bound spans texture defaults and dry fronts" {
    const saturation_pairs = [_][2]f64{
        .{ 0.99, 0.50 },
        .{ 0.95, 0.05 },
        .{ 0.80, 0.01 },
        .{ 0.999, 0.001 },
    };
    for (std.enums.values(retention.SoilTextureClass)) |texture| {
        const parameters = try retention.carselParrishDefault(texture, null);
        for (saturation_pairs) |pair| {
            const wet_head_m = try headAtEffectiveSaturation(parameters, pair[0]);
            const dry_head_m = try headAtEffectiveSaturation(parameters, pair[1]);
            try std.testing.expect(
                try intervalAveragedConductivityQuadratureError(
                    parameters,
                    wet_head_m,
                    dry_head_m,
                ) < 1.0e-6,
            );
        }
    }
}

test "KIRCH-F3 wet limit agrees with the endpoint conductivity" {
    const base_head_m = try headAtEffectiveSaturation(test_parameters, 0.80);
    const endpoint = try test_parameters.hydraulicConductivityMPerH(base_head_m);
    var perturbation: f64 = 1.0e-2;
    var previous_error: f64 = std.math.inf(f64);
    while (perturbation > 1.0e-5) : (perturbation /= 10.0) {
        const other_head_m = base_head_m * (1.0 + perturbation);
        const averaged = try intervalAveragedConductivityMPerH(
            test_parameters,
            base_head_m,
            other_head_m,
        );
        const relative_error = @abs(averaged - endpoint) / endpoint;
        try std.testing.expect(relative_error < 0.1);
        try std.testing.expect(relative_error < previous_error);
        previous_error = relative_error;
    }
}

test "KIRCH-F4 symmetric under swapping the endpoints" {
    const a = try headAtEffectiveSaturation(test_parameters, 0.75);
    const b = try headAtEffectiveSaturation(test_parameters, 0.15);
    const forward = try intervalAveragedConductivityMPerH(test_parameters, a, b);
    const reverse = try intervalAveragedConductivityMPerH(test_parameters, b, a);
    try std.testing.expectEqual(forward, reverse);
}

test "KIRCH-F4b bounded by the wet endpoint and above the dry endpoint" {
    const a = try headAtEffectiveSaturation(test_parameters, 0.75);
    const b = try headAtEffectiveSaturation(test_parameters, 0.15);
    const averaged = try intervalAveragedConductivityMPerH(test_parameters, a, b);
    const wet = try test_parameters.hydraulicConductivityMPerH(a);
    const dry = try test_parameters.hydraulicConductivityMPerH(b);
    try std.testing.expect(averaged <= wet);
    try std.testing.expect(averaged > dry);
}

test "saturated endpoint is handled without a log singularity" {
    const dry = try headAtEffectiveSaturation(test_parameters, 0.20);
    const averaged = try intervalAveragedConductivityMPerH(test_parameters, 0.0, dry);
    try std.testing.expect(averaged > 0);
    try std.testing.expect(averaged <= test_parameters.saturated_hydraulic_conductivity_m_per_h);
}

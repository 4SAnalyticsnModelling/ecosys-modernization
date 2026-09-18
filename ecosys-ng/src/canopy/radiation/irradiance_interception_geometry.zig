// **CURRENT DISPOSITION: SUPERSEDED; TEST-ONLY TRANSLATION.** Production uses
// `canopy/morphology/geometry.zig`; its four-class path now preserves STARTS
// ZSIN/ZCOS literals exactly. The redundant production allocation of this
// state was removed after proving that no runtime or test consumed it.
// The historical A8a audit below is retained as provenance and its former
// dead-wire/source-drift claims no longer describe the current tree.
//
// **HISTORICAL A8a DISPOSITION: GAP, translated and validated but unreached. Do not bind
// here.** This module is a faithful translation of `starts.f:142--181`, the
// STARTS block that tabulates diffuse sky-to-leaf interception geometry:
// `ZSIN`/`ZCOS` leaf inclination at `:142--149`, `ZAZI` leaf azimuth at `:151`,
// `YAZI`/`YSIN`/`YCOS` sky azimuth and elevation at `:154--157`, the `TYSIN`
// sky-sine sum at `:158`, and the triple loop at `:159--181` producing `OMEGA`
// (`:163`), `OMEGX` (`:164`) and the `IALBY` backward-versus-forward scattering
// flag (`:165--179`).
//
// The production owner is `canopy/morphology/geometry.zig`, registered as
// `canopy_geometry` at `src/module_index.zig:179` and reached in production from
// `src/stages/hourly_science_driver.zig:138`
// (`context.canopy_geometry.directSolarIncidenceMapped`) and `:145`, where it is
// passed into `canopy_interception.refreshLayerTransmission`. That file's first
// `test ` line is `:184`, so its `initialize` at `:72` and its per-table loop at
// `:84--95` are production code. It computes the same three tables under
// different names: `OMEGA` is `diffuse_incidence_fraction` (`geometry.zig:93`),
// `OMEGX` is `diffuse_incidence_per_horizontal_area` (`:94`), `IALBY` is
// `diffuse_scattering_direction` (`:95`, via `scatteringDirection` at `:175`),
// and `TYSIN` is `diffuse_sky_horizontal_projection` (`:88`). The signed
// projection `OMEGY` is the same expression in both: `geometry.zig:92` and
// `236--241` here.
//
// What makes this a GAP rather than a plain supersession is the wiring. Unlike
// every other unbound module in this directory, this one is constructed on the
// production path: `src/ecosys_ng.zig:2126` calls `initialize` with inputs taken
// from the bound `canopy_geometry` at `:2127--2133`, `:2135` defers its
// `deinit`, and `:3120` stores the pointer into the `hourly_science_context`
// literal that opens at `:3089` and closes at `:3348`. `ecosys_ng.zig` has its
// first `test ` line at `:8153` of 8155, so all of that is production code. And
// yet nothing ever reads it. A search across `src` for the field access finds
// exactly one hit, the `initialize` call itself; `src/stages` contains no
// occurrence of the name at all. So every run allocates the full projection
// table, fills it, hands it to the hourly context, and discards it. This is the
// write-only shape that the gate's unwritten-field guard structurally cannot
// see, the same class as GRIDCELL-ACC-WRITEONLY-001 and CANOPY-TKG-001. Filed
// as CANOPY-GEOMETRY-DEADWIRE-001.
//
// The family note for this directory,
// `docs/traceability/canopy_radiation_unbound_family_disposition.md`, does not
// cover this module. It counts 22 unbound modules of 27 and dispositions them in
// groups A through I, but the string `irradiance` does not appear in it, and the
// bound four are `layer_distribution.zig`, `optics.zig`, `radiation.zig` and
// `exposure.zig`, which makes 23 unbound rather than 22. This module is the
// missing row. The count in that note is therefore off by one and is named here
// rather than edited.
//
// Two divergences a future binding must not lose. First, the index orders differ:
// `119--120` here lays the table out as
// `[leaf_azimuth][leaf_inclination][sky_azimuth]`, preserving Fortran
// column-major order for `OMEGA(N,M,L)`, while `geometry.zig:100` uses
// `[sky][inclination][leaf_azimuth]`. The two produce identical tables under
// their own accessors and incompatible ones if a raw slice is passed between
// them. Second, both this module and the bound owner depart from the legacy
// lookup in the same way and for the same reason: `starts.f:142--149` hard-codes
// rounded inclination sines, and `geometry.zig:73--79` computes exact midpoints
// of equal inclination intervals instead, which this module then inherits
// because `ecosys_ng.zig:2127--2128` feeds it the bound owner's arrays. The
// module's own test at `280` therefore validates it against the
// midpoint convention, not against the four rounded source constants, despite
// what its name says.
//
// Non-vacuity caveat on that test: it asserts extents and finiteness and a
// bounded range, not values, so it would pass against a differently scaled
// projection. Do not read it as a transcription proof.
// A8a phase 2, src/canopy/radiation directory sweep. Group J of docs/traceability/canopy_radiation_unbound_family_disposition.md
const std = @import("std");

pub const ScatteringDirection = enum(u8) {
    backward = 1,
    forward = 2,
};

pub const Inputs = struct {
    leaf_inclination_sine: []const f64,
    leaf_inclination_cosine: []const f64,
    sky_azimuth_class_count: usize,
    leaf_azimuth_class_count: usize,
    sky_elevation_rad: f64,
    pi: f64,
    reflected_angle_threshold_rad: f64,
};

/// Immutable, heap-owned canopy interception geometry. Three-dimensional
/// fields preserve Fortran column-major order:
/// `[leaf_azimuth][leaf_inclination][sky_azimuth]`.
pub const Geometry = struct {
    allocator: std.mem.Allocator,
    leaf_inclination_sine: []f64,
    leaf_inclination_cosine: []f64,
    leaf_azimuth_rad: []f64,
    sky_azimuth_rad: []f64,
    sky_azimuth_sine: []f64,
    sky_azimuth_cosine: []f64,
    diffuse_leaf_projection_fraction: []f64,
    diffuse_horizontal_projection_fraction: []f64,
    scattering_direction: []ScatteringDirection,
    sky_sine_sum: f64,

    pub fn deinit(self: *Geometry) void {
        self.allocator.free(self.leaf_inclination_sine);
        self.allocator.free(self.leaf_inclination_cosine);
        self.allocator.free(self.leaf_azimuth_rad);
        self.allocator.free(self.sky_azimuth_rad);
        self.allocator.free(self.sky_azimuth_sine);
        self.allocator.free(self.sky_azimuth_cosine);
        self.allocator.free(self.diffuse_leaf_projection_fraction);
        self.allocator.free(self.diffuse_horizontal_projection_fraction);
        self.allocator.free(self.scattering_direction);
        self.* = undefined;
    }

    pub fn index(
        self: Geometry,
        sky_index: usize,
        inclination_index: usize,
        leaf_azimuth_index: usize,
    ) usize {
        return (leaf_azimuth_index * self.leaf_inclination_sine.len +
            inclination_index) * self.sky_azimuth_rad.len + sky_index;
    }
};

/// Source-order translation of legacy `STARTS` lines 142--181.
pub fn initialize(allocator: std.mem.Allocator, inputs: Inputs) !Geometry {
    const inclination_count = inputs.leaf_inclination_sine.len;
    if (inclination_count == 0 or
        inputs.leaf_inclination_cosine.len != inclination_count or
        inputs.sky_azimuth_class_count == 0 or
        inputs.leaf_azimuth_class_count == 0)
    {
        return error.InvalidCanopyGeometryDimensions;
    }
    inline for (.{
        inputs.sky_elevation_rad,
        inputs.pi,
        inputs.reflected_angle_threshold_rad,
    }) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteCanopyGeometry;
    }
    if (inputs.pi <= 0 or
        inputs.sky_elevation_rad <= 0 or
        inputs.sky_elevation_rad >= inputs.pi)
        return error.InvalidCanopyGeometryAngle;
    for (inputs.leaf_inclination_sine, inputs.leaf_inclination_cosine) |
        sine,
        cosine,
    | {
        if (!std.math.isFinite(sine) or !std.math.isFinite(cosine))
            return error.NonFiniteCanopyGeometry;
        if (@abs(sine) > 1 or @abs(cosine) > 1)
            return error.InvalidCanopyGeometryAngle;
    }

    const orientation_count = std.math.mul(
        usize,
        inclination_count,
        inputs.leaf_azimuth_class_count,
    ) catch return error.DimensionOverflow;
    const projection_count = std.math.mul(
        usize,
        orientation_count,
        inputs.sky_azimuth_class_count,
    ) catch return error.DimensionOverflow;

    var geometry: Geometry = .{
        .allocator = allocator,
        .leaf_inclination_sine = try allocator.dupe(
            f64,
            inputs.leaf_inclination_sine,
        ),
        .leaf_inclination_cosine = undefined,
        .leaf_azimuth_rad = undefined,
        .sky_azimuth_rad = undefined,
        .sky_azimuth_sine = undefined,
        .sky_azimuth_cosine = undefined,
        .diffuse_leaf_projection_fraction = undefined,
        .diffuse_horizontal_projection_fraction = undefined,
        .scattering_direction = undefined,
        .sky_sine_sum = 0.0,
    };
    errdefer allocator.free(geometry.leaf_inclination_sine);
    geometry.leaf_inclination_cosine = try allocator.dupe(
        f64,
        inputs.leaf_inclination_cosine,
    );
    errdefer allocator.free(geometry.leaf_inclination_cosine);
    geometry.leaf_azimuth_rad =
        try allocator.alloc(f64, inputs.leaf_azimuth_class_count);
    errdefer allocator.free(geometry.leaf_azimuth_rad);
    geometry.sky_azimuth_rad =
        try allocator.alloc(f64, inputs.sky_azimuth_class_count);
    errdefer allocator.free(geometry.sky_azimuth_rad);
    geometry.sky_azimuth_sine =
        try allocator.alloc(f64, inputs.sky_azimuth_class_count);
    errdefer allocator.free(geometry.sky_azimuth_sine);
    geometry.sky_azimuth_cosine =
        try allocator.alloc(f64, inputs.sky_azimuth_class_count);
    errdefer allocator.free(geometry.sky_azimuth_cosine);
    geometry.diffuse_leaf_projection_fraction =
        try allocator.alloc(f64, projection_count);
    errdefer allocator.free(geometry.diffuse_leaf_projection_fraction);
    geometry.diffuse_horizontal_projection_fraction =
        try allocator.alloc(f64, projection_count);
    errdefer allocator.free(geometry.diffuse_horizontal_projection_fraction);
    geometry.scattering_direction =
        try allocator.alloc(ScatteringDirection, projection_count);
    errdefer allocator.free(geometry.scattering_direction);

    const leaf_azimuth_count_f64: f64 =
        @floatFromInt(inputs.leaf_azimuth_class_count);
    for (0..inputs.leaf_azimuth_class_count) |leaf_azimuth_index| {
        geometry.leaf_azimuth_rad[leaf_azimuth_index] =
            (@as(f64, @floatFromInt(leaf_azimuth_index)) + 0.5) *
            inputs.pi / leaf_azimuth_count_f64;
    }

    const sky_count_f64: f64 = @floatFromInt(inputs.sky_azimuth_class_count);
    for (0..inputs.sky_azimuth_class_count) |sky_index| {
        geometry.sky_azimuth_rad[sky_index] =
            inputs.pi *
            (2.0 * @as(f64, @floatFromInt(sky_index)) + 1.0) /
            sky_count_f64;
        geometry.sky_azimuth_sine[sky_index] =
            @sin(inputs.sky_elevation_rad);
        geometry.sky_azimuth_cosine[sky_index] =
            @cos(inputs.sky_elevation_rad);
        geometry.sky_sine_sum += geometry.sky_azimuth_sine[sky_index];

        for (0..inputs.leaf_azimuth_class_count) |leaf_azimuth_index| {
            const azimuth_cosine = @cos(
                geometry.leaf_azimuth_rad[leaf_azimuth_index] -
                    geometry.sky_azimuth_rad[sky_index],
            );
            for (0..inclination_count) |inclination_index| {
                const signed_projection =
                    geometry.leaf_inclination_cosine[inclination_index] *
                    geometry.sky_azimuth_sine[sky_index] +
                    geometry.leaf_inclination_sine[inclination_index] *
                        geometry.sky_azimuth_cosine[sky_index] *
                        azimuth_cosine;
                if (signed_projection < -1 or signed_projection > 1)
                    return error.InvalidCanopyProjection;
                const index = geometry.index(
                    sky_index,
                    inclination_index,
                    leaf_azimuth_index,
                );
                geometry.diffuse_leaf_projection_fraction[index] =
                    @abs(signed_projection);
                geometry.diffuse_horizontal_projection_fraction[index] =
                    geometry.diffuse_leaf_projection_fraction[index] /
                    geometry.sky_azimuth_sine[sky_index];

                const reflected_angle_rad =
                    if (geometry.leaf_inclination_cosine[inclination_index] >
                    geometry.sky_azimuth_sine[sky_index])
                        std.math.acos(signed_projection)
                    else
                        -std.math.acos(signed_projection);
                const outgoing_angle_rad =
                    if (reflected_angle_rad >
                    inputs.reflected_angle_threshold_rad)
                        inputs.sky_elevation_rad + 2.0 * reflected_angle_rad
                    else
                        inputs.sky_elevation_rad -
                            2.0 * (inputs.pi + reflected_angle_rad);
                geometry.scattering_direction[index] =
                    if (outgoing_angle_rad > 0 and
                    outgoing_angle_rad < inputs.pi)
                        .backward
                    else
                        .forward;
            }
        }
    }
    return geometry;
}

test "STARTS four-class geometry reproduces source constants and extents" {
    var geometry = try initialize(std.testing.allocator, .{
        .leaf_inclination_sine = &.{ 0.195, 0.556, 0.831, 0.981 },
        .leaf_inclination_cosine = &.{ 0.981, 0.831, 0.556, 0.195 },
        .sky_azimuth_class_count = 4,
        .leaf_azimuth_class_count = 4,
        .sky_elevation_rad = 3.1416 / 4.0,
        .pi = 3.1416,
        .reflected_angle_threshold_rad = -1.5708,
    });
    defer geometry.deinit();

    try std.testing.expectEqual(@as(usize, 64), geometry.scattering_direction.len);
    try std.testing.expectApproxEqAbs(
        @as(f64, 3.1416 / 8.0),
        geometry.leaf_azimuth_rad[0],
        1.0e-15,
    );
    try std.testing.expectApproxEqAbs(
        4.0 * @sin(3.1416 / 4.0),
        geometry.sky_sine_sum,
        1.0e-15,
    );
    const index = geometry.index(0, 0, 0);
    const signed_projection =
        0.981 * @sin(3.1416 / 4.0) +
        0.195 * @cos(3.1416 / 4.0) *
            @cos(3.1416 / 8.0 - 3.1416 / 4.0);
    try std.testing.expectApproxEqAbs(
        @abs(signed_projection),
        geometry.diffuse_leaf_projection_fraction[index],
        1.0e-15,
    );
}

test "runtime class counts allocate only requested geometry" {
    var geometry = try initialize(std.testing.allocator, .{
        .leaf_inclination_sine = &.{ 0.5, 0.8 },
        .leaf_inclination_cosine = &.{ 0.866025403784, 0.6 },
        .sky_azimuth_class_count = 3,
        .leaf_azimuth_class_count = 5,
        .sky_elevation_rad = std.math.pi / 4.0,
        .pi = std.math.pi,
        .reflected_angle_threshold_rad = -std.math.pi / 2.0,
    });
    defer geometry.deinit();

    try std.testing.expectEqual(@as(usize, 30), geometry.diffuse_leaf_projection_fraction.len);
    for (geometry.diffuse_leaf_projection_fraction) |fraction| {
        try std.testing.expect(std.math.isFinite(fraction));
        try std.testing.expect(fraction >= 0 and fraction <= 1);
    }
}

const std = @import("std");
const compute = @import("../core/compute.zig");
const organic = @import("../soil/organic/initialization.zig");
const microbial = @import("../soil/microbial/state.zig");
const metabolism = @import("../soil/microbial/metabolism.zig");

const source_complex_count: usize = 6;
const source_population_count: usize = 7;
const source_component_count: usize = 3;
const enabled_complexes = [_]usize{ 0, 1, 2, 5 };

pub const Parameters = struct {
    mixing_rate_per_h: f64,
    timestep_h: f64,
    minimum_layer_thickness_m: f64,
    source_carbon_concentration_conversion_megagrams_per_g: f64 = 1.82e-6,
};

pub const ApplyContext = struct {
    surface_organic: *organic.State,
    soil_microbial: *microbial.State,
    active_soil_layer_count: []const usize,
    surface_activity_g_c_per_step: []const f64,
    topsoil_activity_g_c_per_step: []const f64,
    surface_volume_m3: []const f64,
    topsoil_volume_m3: []const f64,
    surface_area_m2: []const f64,
    topsoil_thickness_m: []const f64,
    surface_dry_mass_megagrams: []const f64,
    topsoil_bulk_density_megagrams_per_m3: []const f64,
    topsoil_organic_carbon_g_per_megagram: []const f64,
    /// Accepted signed L=0/LL=NU transfer per cell. Positive is surface ->
    /// topsoil; negative is topsoil -> surface. This sidecar is output-only.
    accepted_surface_to_topsoil_transfer: ?[]SignedElementTransfer = null,
    parameters: Parameters,
};

pub const SignedElementTransfer = struct {
    carbon_g_c: f64 = 0,
    nitrogen_g_n: f64 = 0,
    phosphorus_g_p: f64 = 0,
};

/// NITRO.F 4168--4275 `L=0`, where `LL=NU`.
///
/// Surface `organic.State.microbial` retains the source
/// `[complex][population][M=1..3]` order. Soil microbial state separates
/// structural M=1,2 from nonstructural M=3; this adapter is their sole
/// cross-domain ownership boundary.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    for (range.first..range.end) |cell| {
        const fraction = try mixingFraction(context.*, cell);
        if (fraction == 0) continue;
        try validateCellTotals(context.*, cell);
        try validateCandidates(context.*, cell, fraction);
    }
    for (range.first..range.end) |cell| {
        const fraction = try mixingFraction(context.*, cell);
        var accepted: SignedElementTransfer = .{};
        if (fraction == 0) {
            if (context.accepted_surface_to_topsoil_transfer) |activity| activity[cell] = accepted;
            continue;
        }
        const surface_is_donor = fraction > 0;
        const magnitude = @abs(fraction);
        for (enabled_complexes) |complex| for (0..source_population_count) |population| {
            const soil_index = try context.soil_microbial.populationIndex(cell, 0, complex, population);
            for (0..source_component_count) |component| {
                const surface_index = surfaceIndex(cell, complex, population, component);
                const soil_pool = if (component < 2)
                    &context.soil_microbial.structural[soil_index * 2 + component]
                else
                    &context.soil_microbial.nonstructural[soil_index];
                accumulateTransfer(&accepted, mixPool(
                    &context.surface_organic.microbial[surface_index],
                    soil_pool,
                    surface_is_donor,
                    magnitude,
                ));
            }
        };
        if (!surface_is_donor) {
            accepted.carbon_g_c = -accepted.carbon_g_c;
            accepted.nitrogen_g_n = -accepted.nitrogen_g_n;
            accepted.phosphorus_g_p = -accepted.phosphorus_g_p;
        }
        if (context.accepted_surface_to_topsoil_transfer) |activity| activity[cell] = accepted;
    }
}

fn validateCellTotals(context: ApplyContext, cell: usize) !void {
    var totals: SignedElementTransfer = .{};
    for (enabled_complexes) |complex| for (0..source_population_count) |population| {
        const soil_index = try context.soil_microbial.populationIndex(cell, 0, complex, population);
        for (0..source_component_count) |component| {
            const surface = context.surface_organic.microbial[surfaceIndex(cell, complex, population, component)];
            const soil = if (component < 2)
                context.soil_microbial.structural[soil_index * 2 + component]
            else
                context.soil_microbial.nonstructural[soil_index];
            inline for (.{ surface, soil }) |pool| inline for (std.meta.fields(organic.ElementPool)) |field| {
                const value = @field(pool, field.name);
                // MICROBIAL-POOL-CARBON-OVERDRAW-HOUR-2678-001. The oracle writes
                // every microbial carbon pool unclamped (`nitro.f:3824`, `:3832`)
                // and reads each one through `AMAX1(0.0, ...)` -- `:431` for
                // OMC(1), `:454` for OMC(2), `:2094` and `:2532` for OMC(3). Those
                // read clamps exist precisely because a stored pool can be
                // negative, so rejecting a negative pool in storage is an invented
                // domain. Non-finite stays fatal.
                if (!std.math.isFinite(value))
                    return error.InvalidSurfaceTopsoilMicrobialMixingPool;
                const next = @field(totals, field.name) + value;
                if (!std.math.isFinite(next))
                    return error.InvalidSurfaceTopsoilMicrobialMixingPool;
                @field(totals, field.name) = next;
            };
        }
    };
}

fn mixingFraction(context: ApplyContext, cell: usize) !f64 {
    const topsoil = cell * context.soil_microbial.layer_count;
    const surface_thickness_m =
        context.surface_volume_m3[cell] / context.surface_area_m2[cell];
    if (context.active_soil_layer_count[cell] == 0 or
        context.surface_dry_mass_megagrams[cell] <= 0 or
        context.topsoil_bulk_density_megagrams_per_m3[topsoil] <= 0)
        return 0;
    const surface_density = context.surface_activity_g_c_per_step[cell] /
        context.surface_volume_m3[cell];
    const topsoil_density = context.topsoil_activity_g_c_per_step[topsoil] /
        context.topsoil_volume_m3[topsoil];
    const surface_carbon_g_per_megagram =
        try context.surface_organic.totalCarbon_g_c(cell) /
        context.surface_dry_mass_megagrams[cell];
    const shared_carbon =
        @min(
            surface_carbon_g_per_megagram,
            context.topsoil_organic_carbon_g_per_megagram[topsoil],
        ) *
        context.parameters.source_carbon_concentration_conversion_megagrams_per_g;
    const fraction =
        2 * context.parameters.mixing_rate_per_h *
        (surface_density - topsoil_density) *
        context.parameters.timestep_h /
        (surface_thickness_m + context.topsoil_thickness_m[topsoil]) *
        shared_carbon;
    if (!std.math.isFinite(fraction)) return error.NonFiniteSurfaceTopsoilMicrobialMixingFraction;
    if (@abs(fraction) > 1) return error.SurfaceTopsoilMicrobialMixingFractionExceedsInventory;
    return fraction;
}

fn validateCandidates(context: ApplyContext, cell: usize, fraction: f64) !void {
    const surface_is_donor = fraction > 0;
    const magnitude = @abs(fraction);
    for (enabled_complexes) |complex| for (0..source_population_count) |population| {
        const soil_index = try context.soil_microbial.populationIndex(cell, 0, complex, population);
        for (0..source_component_count) |component| {
            const surface = context.surface_organic.microbial[surfaceIndex(cell, complex, population, component)];
            const soil = if (component < 2)
                context.soil_microbial.structural[soil_index * 2 + component]
            else
                context.soil_microbial.nonstructural[soil_index];
            try validatePool(surface);
            try validatePool(soil);
            inline for (std.meta.fields(metabolism.ElementalPool)) |field| {
                const donor_value = if (surface_is_donor)
                    @field(surface, field.name)
                else
                    @field(soil, field.name);
                const transfer = @max(0, donor_value) * magnitude;
                const next_surface = @field(surface, field.name) +
                    (if (surface_is_donor) -transfer else transfer);
                const next_soil = @field(soil, field.name) +
                    (if (surface_is_donor) transfer else -transfer);
                // MICROBIAL-POOL-CARBON-OVERDRAW-HOUR-2678-001. `transfer` above
                // already clamps the donor with `@max(0, donor_value)`, which is
                // this path's counterpart of the oracle's `AMAX1(0.0, ...)` on
                // every microbial-pool read (`nitro.f:431`, `:454`, `:2094`,
                // `:2532`). So when a pool is negative the transfer is zero and
                // both values pass through unchanged, and a negative result here
                // can only be a pre-existing negative this mixing did not create --
                // which the oracle permits in storage, writing OMC unclamped at
                // `:3824` and `:3832`.
                //
                // `transfer >= 0` and is drawn from a non-negative donor, so mixing
                // can never make a pool worse. Non-finite stays fatal.
                if (!std.math.isFinite(next_surface) or !std.math.isFinite(next_soil))
                    return error.InvalidSurfaceTopsoilMicrobialMixingResult;
            }
        }
    };
}

fn mixPool(
    surface: *organic.ElementPool,
    soil: *metabolism.ElementalPool,
    surface_is_donor: bool,
    fraction: f64,
) SignedElementTransfer {
    var result: SignedElementTransfer = .{};
    inline for (std.meta.fields(organic.ElementPool)) |field| {
        const donor_value = if (surface_is_donor)
            @field(surface.*, field.name)
        else
            @field(soil.*, field.name);
        const transfer = @max(0, donor_value) * fraction;
        @field(surface, field.name) += if (surface_is_donor) -transfer else transfer;
        @field(soil, field.name) += if (surface_is_donor) transfer else -transfer;
        @field(result, field.name) = transfer;
    }
    return result;
}

fn accumulateTransfer(total: *SignedElementTransfer, value: SignedElementTransfer) void {
    total.carbon_g_c += value.carbon_g_c;
    total.nitrogen_g_n += value.nitrogen_g_n;
    total.phosphorus_g_p += value.phosphorus_g_p;
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const cells = context.soil_microbial.cell_count;
    const layers = try std.math.mul(
        usize,
        cells,
        context.soil_microbial.layer_count,
    );
    if (range.first > range.end or range.end > cells or
        context.surface_organic.layer_count != cells or
        context.soil_microbial.substrate_count < source_complex_count or
        context.soil_microbial.population_count < source_population_count)
        return error.InvalidSurfaceTopsoilMicrobialMixingDimensions;
    inline for (.{
        context.active_soil_layer_count.len,
        context.surface_activity_g_c_per_step.len,
        context.surface_volume_m3.len,
        context.surface_area_m2.len,
        context.surface_dry_mass_megagrams.len,
        if (context.accepted_surface_to_topsoil_transfer) |activity| activity.len else cells,
    }) |length| if (length != cells) return error.InvalidSurfaceTopsoilMicrobialMixingDimensions;
    inline for (.{
        context.topsoil_activity_g_c_per_step.len,
        context.topsoil_volume_m3.len,
        context.topsoil_thickness_m.len,
        context.topsoil_bulk_density_megagrams_per_m3.len,
        context.topsoil_organic_carbon_g_per_megagram.len,
    }) |length| if (length != layers) return error.InvalidSurfaceTopsoilMicrobialMixingDimensions;
    inline for (std.meta.fields(Parameters)) |field| {
        const value = @field(context.parameters, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSurfaceTopsoilMicrobialMixingParameter;
    }
    for (range.first..range.end) |cell| {
        const topsoil = cell * context.soil_microbial.layer_count;
        if (context.active_soil_layer_count[cell] > context.soil_microbial.layer_count)
            return error.InvalidSurfaceTopsoilMicrobialMixingDimensions;
        inline for (.{
            context.surface_activity_g_c_per_step[cell],
            context.surface_volume_m3[cell],
            context.surface_area_m2[cell],
            context.surface_dry_mass_megagrams[cell],
            context.topsoil_activity_g_c_per_step[topsoil],
            context.topsoil_volume_m3[topsoil],
            context.topsoil_thickness_m[topsoil],
            context.topsoil_bulk_density_megagrams_per_m3[topsoil],
            context.topsoil_organic_carbon_g_per_megagram[topsoil],
        }) |value| if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSurfaceTopsoilMicrobialMixingInput;
        if (context.surface_area_m2[cell] <= 0)
            return error.InvalidSurfaceTopsoilMicrobialMixingGeometry;
        if (context.active_soil_layer_count[cell] > 0 and
            context.surface_dry_mass_megagrams[cell] > 0 and
            context.topsoil_bulk_density_megagrams_per_m3[topsoil] > 0 and
            (context.surface_volume_m3[cell] <= 0 or
                context.topsoil_volume_m3[topsoil] <= 0 or
                context.topsoil_thickness_m[topsoil] <= 0))
            return error.InvalidSurfaceTopsoilMicrobialMixingGeometry;
    }
}

fn validatePool(pool: anytype) !void {
    // Same oracle citation as the cell-totals guard above: microbial carbon pools
    // are written unclamped (`nitro.f:3824`, `:3832`) and read through
    // `AMAX1(0.0, ...)` (`:431`, `:454`, `:2094`, `:2532`), so a negative stored
    // pool is oracle-permitted. Non-finite stays fatal.
    inline for (std.meta.fields(@TypeOf(pool))) |field|
        if (!std.math.isFinite(@field(pool, field.name)))
            return error.InvalidSurfaceTopsoilMicrobialMixingPool;
}

fn surfaceIndex(cell: usize, complex: usize, population: usize, component: usize) usize {
    return (((cell * source_complex_count + complex) * source_population_count + population) *
        source_component_count + component);
}

fn fixture(
    surface: *organic.State,
    soil: *microbial.State,
    active: []const usize,
    surface_volume: []const f64,
) ApplyContext {
    return .{
        .surface_organic = surface,
        .soil_microbial = soil,
        .active_soil_layer_count = active,
        .surface_activity_g_c_per_step = &.{2},
        .topsoil_activity_g_c_per_step = &.{1},
        .surface_volume_m3 = surface_volume,
        .topsoil_volume_m3 = &.{1},
        .surface_area_m2 = &.{1},
        .topsoil_thickness_m = &.{1},
        .surface_dry_mass_megagrams = &.{1},
        .topsoil_bulk_density_megagrams_per_m3 = &.{1},
        .topsoil_organic_carbon_g_per_megagram = &.{1.0e6},
        .parameters = .{ .mixing_rate_per_h = 0.1, .timestep_h = 1, .minimum_layer_thickness_m = 0.01 },
    };
}

test "surface to first soil layer mixing conserves C N P in exact source pools" {
    var surface = try organic.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try microbial.State.init(std.testing.allocator, 1, 1, 6, 7);
    defer soil.deinit();
    const surface_index = surfaceIndex(0, 0, 0, 0);
    surface.microbial[surface_index] = .{ .carbon_g_c = 10, .nitrogen_g_n = 2, .phosphorus_g_p = 1 };
    surface.dissolved[0].carbon_g_c = 999_990;
    var context = fixture(&surface, &soil, &.{1}, &.{1});
    var accepted = [_]SignedElementTransfer{.{}};
    context.accepted_surface_to_topsoil_transfer = &accepted;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const soil_index = try soil.populationIndex(0, 0, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 10), surface.microbial[surface_index].carbon_g_c + soil.structural[soil_index * 2].carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2), surface.microbial[surface_index].nitrogen_g_n + soil.structural[soil_index * 2].nitrogen_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1), surface.microbial[surface_index].phosphorus_g_p + soil.structural[soil_index * 2].phosphorus_g_p, 1e-14);
    try std.testing.expect(surface.microbial[surface_index].carbon_g_c < 10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.82), accepted[0].carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.364), accepted[0].nitrogen_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.182), accepted[0].phosphorus_g_p, 1e-14);
}

test "topsoil to surface activity retains signed source direction" {
    var surface = try organic.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try microbial.State.init(std.testing.allocator, 1, 1, 6, 7);
    defer soil.deinit();
    surface.dissolved[0].carbon_g_c = 1.0e6;
    const soil_index = try soil.populationIndex(0, 0, 0, 0);
    soil.structural[soil_index * 2] = .{ .carbon_g_c = 10, .nitrogen_g_n = 2, .phosphorus_g_p = 1 };
    var context = fixture(&surface, &soil, &.{1}, &.{1});
    context.surface_activity_g_c_per_step = &.{1};
    context.topsoil_activity_g_c_per_step = &.{2};
    var accepted = [_]SignedElementTransfer{.{}};
    context.accepted_surface_to_topsoil_transfer = &accepted;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(surface.microbial[0].carbon_g_c > 0);
    try std.testing.expect(accepted[0].carbon_g_c < 0);
    try std.testing.expect(accepted[0].nitrogen_g_n < 0);
    try std.testing.expect(accepted[0].phosphorus_g_p < 0);
}

test "surface branch does not apply the mineral-layer DLYRM gate" {
    var surface = try organic.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try microbial.State.init(std.testing.allocator, 1, 1, 6, 7);
    defer soil.deinit();
    const index = surfaceIndex(0, 0, 0, 0);
    surface.microbial[index].carbon_g_c = 10;
    surface.dissolved[0].carbon_g_c = 999_990;
    var context = fixture(&surface, &soil, &.{1}, &.{0.001});
    context.parameters.mixing_rate_per_h = 1.0e-6;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(surface.microbial[index].carbon_g_c < 10);
}

test "no-neighbor and zero-mass surface cells do not mix" {
    var inactive_surface = try organic.State.init(std.testing.allocator, 1);
    defer inactive_surface.deinit();
    var inactive_soil = try microbial.State.init(std.testing.allocator, 1, 1, 6, 7);
    defer inactive_soil.deinit();
    const inactive_index = surfaceIndex(0, 0, 0, 0);
    inactive_surface.microbial[inactive_index].carbon_g_c = 10;
    inactive_surface.dissolved[0].carbon_g_c = 999_990;
    var inactive_context = fixture(&inactive_surface, &inactive_soil, &.{0}, &.{1});
    try applyTile(&inactive_context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(
        @as(f64, 10),
        inactive_surface.microbial[inactive_index].carbon_g_c,
    );
    inactive_context.active_soil_layer_count = &.{1};
    inactive_context.surface_dry_mass_megagrams = &.{0};
    try applyTile(&inactive_context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(
        @as(f64, 10),
        inactive_surface.microbial[inactive_index].carbon_g_c,
    );
}

test "invalid pool fails before either owner is mutated" {
    var surface = try organic.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var soil = try microbial.State.init(std.testing.allocator, 1, 1, 6, 7);
    defer soil.deinit();
    const first = surfaceIndex(0, 0, 0, 0);
    const later = surfaceIndex(0, 5, 6, 2);
    surface.microbial[first].carbon_g_c = 10;
    surface.dissolved[0].carbon_g_c = 999_990;
    surface.microbial[later].carbon_g_c = std.math.nan(f64);
    var context = fixture(&surface, &soil, &.{1}, &.{1});
    var accepted = [_]SignedElementTransfer{.{ .carbon_g_c = 7 }};
    context.accepted_surface_to_topsoil_transfer = &accepted;
    try std.testing.expectError(error.InvalidOrganicCarbonState, applyTile(&context, .{ .first = 0, .end = 1 }));
    try std.testing.expectEqual(@as(f64, 10), surface.microbial[first].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), soil.structural[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 7), accepted[0].carbon_g_c);
}

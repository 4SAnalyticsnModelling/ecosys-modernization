const std = @import("std");
const schedule = @import("fertilizer_schedule.zig");
const surface = @import("../surface/litter_fertilizer.zig");
const soil_dissolution = @import("../soil/nutrients/fertilizer_dissolution.zig");
const reactive_nitrogen_state = @import("../soil/nutrients/reactive_nitrogen_state.zig");

/// Heap-owned undissolved nitrogen fertilizer for every runtime soil layer.
/// Surface broadcast material remains in `surface_litter_fertilizer.State`;
/// banded material is retained in soil even when its requested depth is zero.
pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    layer_capacity: usize,
    soil: []soil_dissolution.FertilizerState,
    initial_urease_inhibition_fraction: []f64,
    current_urease_inhibition_fraction: []f64,
    formulation: []u8,
    daily_nitrogen_input_g_n: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, layer_capacity: usize) !State {
        if (cell_count == 0 or layer_capacity == 0) return error.ZeroFertilizerInventoryExtent;
        const count = try std.math.mul(usize, cell_count, layer_capacity);
        const soil = try allocator.alloc(soil_dissolution.FertilizerState, count);
        errdefer allocator.free(soil);
        const initial = try allocator.alloc(f64, count);
        errdefer allocator.free(initial);
        const current = try allocator.alloc(f64, count);
        errdefer allocator.free(current);
        const formulation = try allocator.alloc(u8, count);
        errdefer allocator.free(formulation);
        const daily_nitrogen_input_g_n = try allocator.alloc(f64, cell_count);
        @memset(soil, zeroSoilInventory());
        @memset(initial, 0);
        @memset(current, 0);
        @memset(formulation, 0);
        @memset(daily_nitrogen_input_g_n, 0);
        return .{ .allocator = allocator, .cell_count = cell_count, .layer_capacity = layer_capacity, .soil = soil, .initial_urease_inhibition_fraction = initial, .current_urease_inhibition_fraction = current, .formulation = formulation, .daily_nitrogen_input_g_n = daily_nitrogen_input_g_n };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.soil);
        self.allocator.free(self.initial_urease_inhibition_fraction);
        self.allocator.free(self.current_urease_inhibition_fraction);
        self.allocator.free(self.formulation);
        self.allocator.free(self.daily_nitrogen_input_g_n);
        self.* = undefined;
    }

    pub fn index(self: State, cell: usize, layer: usize) !usize {
        if (cell >= self.cell_count or layer >= self.layer_capacity) return error.FertilizerInventoryIndexOutOfBounds;
        return cell * self.layer_capacity + layer;
    }

    pub fn resetDaily(self: *State) void {
        @memset(self.daily_nitrogen_input_g_n, 0);
    }
};

/// Applies only the nitrogen portion of one management event. The caller must
/// dispatch P, Ca, residue, and manure through their respective mass ledgers.
///
/// `reactive_nitrogen` is the sole owner of the runtime nitrification-
/// inhibition activity arrays consumed by `soil/microbial/nitrification_step
/// .zig` (`FERT-002`). It must be indexed identically to `state`
/// (`cell * layer_capacity + layer`); this is validated below rather than
/// assumed.
pub fn applyEventNitrogen(
    state: *State,
    surface_state: *surface.State,
    reactive_nitrogen: *reactive_nitrogen_state.State,
    cell: usize,
    cell_area_m2: f64,
    nitrogen_molar_mass_g_per_mol: f64,
    surface_litter_cover_fraction: f64,
    active_layer_thickness_m: []const f64,
    event: schedule.Event,
) !void {
    if (cell >= state.cell_count or cell >= surface_state.cells.len) return error.FertilizerInventoryIndexOutOfBounds;
    if (active_layer_thickness_m.len == 0 or active_layer_thickness_m.len > state.layer_capacity) return error.InvalidActiveSoilLayerCount;
    const soil_extent = try std.math.mul(usize, state.cell_count, state.layer_capacity);
    if (reactive_nitrogen.initial_nitrification_inhibition_activity.len != soil_extent or
        reactive_nitrogen.current_nitrification_inhibition_activity.len != soil_extent)
        return error.FertilizerNitrificationInhibitorDimensionMismatch;
    if (!std.math.isFinite(cell_area_m2) or cell_area_m2 <= 0 or !std.math.isFinite(nitrogen_molar_mass_g_per_mol) or nitrogen_molar_mass_g_per_mol <= 0) return error.InvalidFertilizerMassConversion;
    if (!std.math.isFinite(event.application_depth_m) or event.application_depth_m < 0 or !std.math.isFinite(surface_litter_cover_fraction) or surface_litter_cover_fraction < 0 or surface_litter_cover_fraction > 1) return error.InvalidFertilizerApplication;
    for (active_layer_thickness_m) |thickness| if (!std.math.isFinite(thickness) or thickness <= 0) return error.InvalidSoilLayerThickness;

    const conversion_mol_per_g_per_m2 = cell_area_m2 / nitrogen_molar_mass_g_per_mol;
    const n = event.nitrogen_g_per_m2;
    const broadcast = [_]f64{ n.broadcast_ammonium, n.broadcast_ammonia, n.broadcast_urea, n.broadcast_nitrate };
    const banded = [_]f64{ n.banded_ammonium, n.banded_ammonia, n.banded_urea, n.banded_nitrate };
    for (broadcast ++ banded) |amount| if (!std.math.isFinite(amount) or amount < 0) return error.InvalidFertilizerApplication;
    const total_input_g_n = (n.broadcast_ammonium + n.broadcast_ammonia + n.broadcast_urea + n.broadcast_nitrate +
        n.banded_ammonium + n.banded_ammonia + n.banded_urea + n.banded_nitrate) * cell_area_m2;
    const daily_input_next = state.daily_nitrogen_input_g_n[cell] + total_input_g_n;
    if (!std.math.isFinite(daily_input_next)) return error.FertilizerInventoryOverflow;

    const soil_layer = try layerAtDepth(active_layer_thickness_m, event.application_depth_m);
    const soil_index = try state.index(cell, soil_layer);
    var next_surface = surface_state.cells[cell];
    var next_surface_formulation = surface_state.formulation[cell];
    var next_soil = state.soil[soil_index];
    const banded_total_g_n_per_m2 = n.banded_ammonium + n.banded_ammonia + n.banded_urea + n.banded_nitrate;
    const surface_target = event.application_depth_m == 0 and
        banded_total_g_n_per_m2 == 0 and
        event.phosphorus_g_per_m2.banded_monocalcium_phosphate == 0 and
        event.calcium_carbonate_g_ca_per_m2 == 0 and
        event.calcium_sulfate_g_ca_per_m2 == 0;
    if (surface_target) {
        // HOUR1 partitions NH4, urea, and NO3 by litter cover. Broadcast NH3
        // bypasses litter and enters the upper mineral layer in full.
        next_surface.ammonium_mol_n += n.broadcast_ammonium * conversion_mol_per_g_per_m2 * surface_litter_cover_fraction;
        next_surface.urea_mol_n += n.broadcast_urea * conversion_mol_per_g_per_m2 * surface_litter_cover_fraction;
        next_surface.nitrate_mol_n += n.broadcast_nitrate * conversion_mol_per_g_per_m2 * surface_litter_cover_fraction;
        const bare_fraction = 1.0 - surface_litter_cover_fraction;
        next_soil.broadcast_ammonium_mol_n += n.broadcast_ammonium * conversion_mol_per_g_per_m2 * bare_fraction;
        next_soil.broadcast_ammonia_mol_n += n.broadcast_ammonia * conversion_mol_per_g_per_m2;
        next_soil.broadcast_urea_mol_n += n.broadcast_urea * conversion_mol_per_g_per_m2 * bare_fraction;
        next_soil.broadcast_nitrate_mol_n += n.broadcast_nitrate * conversion_mol_per_g_per_m2 * bare_fraction;
    } else {
        next_soil.broadcast_ammonium_mol_n += n.broadcast_ammonium * conversion_mol_per_g_per_m2;
        next_soil.broadcast_ammonia_mol_n += n.broadcast_ammonia * conversion_mol_per_g_per_m2;
        next_soil.broadcast_urea_mol_n += n.broadcast_urea * conversion_mol_per_g_per_m2;
        next_soil.broadcast_nitrate_mol_n += n.broadcast_nitrate * conversion_mol_per_g_per_m2;
    }
    next_soil.banded_ammonium_mol_n += n.banded_ammonium * conversion_mol_per_g_per_m2;
    next_soil.banded_ammonia_mol_n += n.banded_ammonia * conversion_mol_per_g_per_m2;
    next_soil.banded_urea_mol_n += n.banded_urea * conversion_mol_per_g_per_m2;
    next_soil.banded_nitrate_mol_n += n.banded_nitrate * conversion_mol_per_g_per_m2;

    const surface_urea_applied = surface_target and surface_litter_cover_fraction > 0 and n.broadcast_urea > 0;
    const soil_urea_applied = n.banded_urea > 0 or (!surface_target and n.broadcast_urea > 0) or (surface_target and surface_litter_cover_fraction < 1 and n.broadcast_urea > 0);
    if (surface_urea_applied) {
        next_surface.initial_urease_inhibition_fraction = 1;
        next_surface.current_urease_inhibition_fraction = 1;
        next_surface_formulation = event.fertilizer_formulation;
    }
    // hour1.f:931-939 (`DO 9964`) resets the urease-inhibitor activity over
    // *every* soil layer of the cell whenever a urea event fires, arming only
    // the target layer and hard-clamping every other layer to 0 -- not just
    // leaving them to decay on their own schedule. FERT-002 finding 2: the
    // previous translation only ever wrote `soil_index`, so a second urea
    // event at a different depth left the first depth's inhibitor stale.
    if (soil_urea_applied) {
        for (0..active_layer_thickness_m.len) |layer| {
            const idx = try state.index(cell, layer);
            const activity: f64 = if (layer == soil_layer) 1 else 0;
            state.initial_urease_inhibition_fraction[idx] = activity;
            state.current_urease_inhibition_fraction[idx] = activity;
        }
        state.formulation[soil_index] = event.fertilizer_formulation;
    }
    // hour1.f:941-951 (`IF(IYTYP(0)==3.OR.==4)THEN ... DO 9965`) is a sibling
    // of the urea block above, not nested inside it (confirmed by counting
    // `IF`/`ENDIF` nesting forward from :923: the `ENDIF` at :940 closes the
    // urea gate, so the nitrification-inhibitor block that follows at :941 is
    // its own, independently-gated `IF`). It fires whenever the fertilizer
    // formulation itself is nitrification-inhibited (3 or 4), regardless of
    // whether this event actually carried any urea. FERT-002 finding 1: no
    // Zig writer previously ever set the nitrification-inhibitor activity, so
    // `nitrification_step.zig` always read the permanent zero-initialized
    // value and ran uninhibited.
    const nitrification_reset = event.fertilizer_formulation == 3 or event.fertilizer_formulation == 4;
    if (nitrification_reset) {
        for (0..active_layer_thickness_m.len) |layer| {
            const idx = try state.index(cell, layer);
            const activity: f64 = if (layer == soil_layer) 1 else 0;
            reactive_nitrogen.initial_nitrification_inhibition_activity[idx] = activity;
            reactive_nitrogen.current_nitrification_inhibition_activity[idx] = activity;
        }
    }
    try validateFiniteInventory(next_surface, next_soil);
    surface_state.cells[cell] = next_surface;
    surface_state.formulation[cell] = next_surface_formulation;
    state.soil[soil_index] = next_soil;
    state.daily_nitrogen_input_g_n[cell] = daily_input_next;
}

/// ISSUE-090. `LFDPTH` plus the two geometry scalars a band activation needs:
/// the application layer's own upper face (`CDPTH(L-1)`) and its thickness
/// (`DLYR(3,L)`). Walks exactly the same boundaries as `layerAtDepth`, so the
/// index it returns is the one `applyEventNitrogen` places the material in.
pub const ApplicationLayer = struct {
    index: usize,
    upper_depth_m: f64,
    thickness_m: f64,
};

pub fn applicationLayer(thickness_m: []const f64, depth_m: f64) !ApplicationLayer {
    var upper_m: f64 = 0;
    for (thickness_m, 0..) |thickness, layer| {
        const lower_m = upper_m + thickness;
        if (depth_m <= lower_m) return .{
            .index = layer,
            .upper_depth_m = upper_m,
            .thickness_m = thickness,
        };
        upper_m = lower_m;
    }
    return error.FertilizerApplicationBelowSoilProfile;
}

fn layerAtDepth(thickness_m: []const f64, depth_m: f64) !usize {
    var lower_boundary_m: f64 = 0;
    for (thickness_m, 0..) |thickness, layer| {
        lower_boundary_m += thickness;
        if (depth_m <= lower_boundary_m) return layer;
    }
    return error.FertilizerApplicationBelowSoilProfile;
}

fn zeroSoilInventory() soil_dissolution.FertilizerState {
    return .{ .broadcast_ammonium_mol_n = 0, .broadcast_ammonia_mol_n = 0, .broadcast_urea_mol_n = 0, .broadcast_nitrate_mol_n = 0, .banded_ammonium_mol_n = 0, .banded_ammonia_mol_n = 0, .banded_urea_mol_n = 0, .banded_nitrate_mol_n = 0 };
}

fn validateFiniteInventory(surface_inventory: surface.Inventory, soil_inventory: soil_dissolution.FertilizerState) !void {
    inline for (@typeInfo(surface.Inventory).@"struct".fields) |field| if (!std.math.isFinite(@field(surface_inventory, field.name)) or @field(surface_inventory, field.name) < 0) return error.FertilizerApplicationOverflow;
    inline for (@typeInfo(soil_dissolution.FertilizerState).@"struct".fields) |field| if (!std.math.isFinite(@field(soil_inventory, field.name)) or @field(soil_inventory, field.name) < 0) return error.FertilizerApplicationOverflow;
}

test "fertilizer event conversion conserves nitrogen and honors depth and bands" {
    var state = try State.init(std.testing.allocator, 1, 3);
    defer state.deinit();
    var litter = try surface.State.init(std.testing.allocator, 1);
    defer litter.deinit();
    var reactive = try reactive_nitrogen_state.State.init(std.testing.allocator, 3, 1);
    defer reactive.deinit();
    const event: schedule.Event = .{
        .date = .{ .day = 1, .month = 5, .year = 2001 },
        .nitrogen_g_per_m2 = .{ .broadcast_ammonium = 14, .broadcast_ammonia = 0, .broadcast_urea = 28, .broadcast_nitrate = 42, .banded_ammonium = 14, .banded_ammonia = 28, .banded_urea = 42, .banded_nitrate = 56 },
        .phosphorus_g_per_m2 = .{ .broadcast_monocalcium_phosphate = 0, .banded_monocalcium_phosphate = 0, .broadcast_hydroxyapatite = 0 },
        .calcium_carbonate_g_ca_per_m2 = 0,
        .calcium_sulfate_g_ca_per_m2 = 0,
        .plant_residue_g_per_m2 = .{ .carbon = 0, .nitrogen = 0, .phosphorus = 0 },
        .manure_g_per_m2 = .{ .carbon = 0, .nitrogen = 0, .phosphorus = 0 },
        .application_depth_m = 0,
        .band_row_width_m = 0.1,
        .fertilizer_formulation = 4,
        .plant_residue_type = 0,
        .manure_type = 0,
    };
    try applyEventNitrogen(&state, &litter, &reactive, 0, 2, 14, 0.25, &.{ 0.1, 0.2, 0.3 }, event);
    try std.testing.expectEqual(@as(f64, 0), litter.cells[0].ammonium_mol_n + litter.cells[0].urea_mol_n + litter.cells[0].nitrate_mol_n);
    try std.testing.expectApproxEqAbs(@as(f64, 12), state.soil[0].broadcast_ammonium_mol_n + state.soil[0].broadcast_ammonia_mol_n + state.soil[0].broadcast_urea_mol_n + state.soil[0].broadcast_nitrate_mol_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 20), state.soil[0].banded_ammonium_mol_n + state.soil[0].banded_ammonia_mol_n + state.soil[0].banded_urea_mol_n + state.soil[0].banded_nitrate_mol_n, 1e-14);
    try std.testing.expectEqual(@as(f64, 448), state.daily_nitrogen_input_g_n[0]);
    state.resetDaily();
    try std.testing.expectEqual(@as(f64, 0), state.daily_nitrogen_input_g_n[0]);
    try std.testing.expectEqual(@as(u8, 0), litter.formulation[0]);
    try std.testing.expectEqual(@as(u8, 4), state.formulation[0]);
    // FERT-002 finding 1: formulation 4 (slow release + nitrification
    // inhibitor) must activate the nitrification-inhibitor activity at the
    // target layer even though this event's urea landed entirely in litter,
    // not soil (soil_urea_applied is false here).
    try std.testing.expectEqual(@as(f64, 1), reactive.initial_nitrification_inhibition_activity[0]);
    try std.testing.expectEqual(@as(f64, 1), reactive.current_nitrification_inhibition_activity[0]);
}

test "FERT-002: a second urea event at a different depth clears the first depth's urease inhibitor" {
    var state = try State.init(std.testing.allocator, 1, 3);
    defer state.deinit();
    var litter = try surface.State.init(std.testing.allocator, 1);
    defer litter.deinit();
    var reactive = try reactive_nitrogen_state.State.init(std.testing.allocator, 3, 1);
    defer reactive.deinit();
    const first_event: schedule.Event = .{
        .date = .{ .day = 1, .month = 5, .year = 2001 },
        .nitrogen_g_per_m2 = .{ .broadcast_ammonium = 0, .broadcast_ammonia = 0, .broadcast_urea = 0, .broadcast_nitrate = 0, .banded_ammonium = 0, .banded_ammonia = 0, .banded_urea = 10, .banded_nitrate = 0 },
        .phosphorus_g_per_m2 = .{ .broadcast_monocalcium_phosphate = 0, .banded_monocalcium_phosphate = 0, .broadcast_hydroxyapatite = 0 },
        .calcium_carbonate_g_ca_per_m2 = 0,
        .calcium_sulfate_g_ca_per_m2 = 0,
        .plant_residue_g_per_m2 = .{ .carbon = 0, .nitrogen = 0, .phosphorus = 0 },
        .manure_g_per_m2 = .{ .carbon = 0, .nitrogen = 0, .phosphorus = 0 },
        .application_depth_m = 0.05,
        .band_row_width_m = 0.1,
        .fertilizer_formulation = 3,
        .plant_residue_type = 0,
        .manure_type = 0,
    };
    try applyEventNitrogen(&state, &litter, &reactive, 0, 2, 14, 0.25, &.{ 0.1, 0.1, 0.1 }, first_event);
    try std.testing.expectEqual(@as(f64, 1), state.initial_urease_inhibition_fraction[0]);
    try std.testing.expectEqual(@as(f64, 1), state.current_urease_inhibition_fraction[0]);
    try std.testing.expectEqual(@as(f64, 1), reactive.initial_nitrification_inhibition_activity[0]);

    var second_event = first_event;
    second_event.application_depth_m = 0.25;
    try applyEventNitrogen(&state, &litter, &reactive, 0, 2, 14, 0.25, &.{ 0.1, 0.1, 0.1 }, second_event);
    // hour1.f:931-939: arming the new depth (layer 2) must hard-clamp the
    // stale depth (layer 0) back to 0, not leave it to decay on its own.
    try std.testing.expectEqual(@as(f64, 0), state.initial_urease_inhibition_fraction[0]);
    try std.testing.expectEqual(@as(f64, 0), state.current_urease_inhibition_fraction[0]);
    try std.testing.expectEqual(@as(f64, 1), state.initial_urease_inhibition_fraction[2]);
    try std.testing.expectEqual(@as(f64, 1), state.current_urease_inhibition_fraction[2]);
    // hour1.f:941-951: same hard reset for the nitrification inhibitor.
    try std.testing.expectEqual(@as(f64, 0), reactive.initial_nitrification_inhibition_activity[0]);
    try std.testing.expectEqual(@as(f64, 0), reactive.current_nitrification_inhibition_activity[0]);
    try std.testing.expectEqual(@as(f64, 1), reactive.initial_nitrification_inhibition_activity[2]);
    try std.testing.expectEqual(@as(f64, 1), reactive.current_nitrification_inhibition_activity[2]);
}

test "zero-depth broadcast nitrogen follows litter cover while ammonia enters topsoil" {
    var state = try State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    var litter = try surface.State.init(std.testing.allocator, 1);
    defer litter.deinit();
    var reactive = try reactive_nitrogen_state.State.init(std.testing.allocator, 1, 1);
    defer reactive.deinit();
    const event: schedule.Event = .{
        .date = .{ .day = 1, .month = 5, .year = 2001 },
        .nitrogen_g_per_m2 = .{ .broadcast_ammonium = 14, .broadcast_ammonia = 28, .broadcast_urea = 42, .broadcast_nitrate = 56, .banded_ammonium = 0, .banded_ammonia = 0, .banded_urea = 0, .banded_nitrate = 0 },
        .phosphorus_g_per_m2 = .{ .broadcast_monocalcium_phosphate = 0, .banded_monocalcium_phosphate = 0, .broadcast_hydroxyapatite = 0 },
        .calcium_carbonate_g_ca_per_m2 = 0,
        .calcium_sulfate_g_ca_per_m2 = 0,
        .plant_residue_g_per_m2 = .{ .carbon = 0, .nitrogen = 0, .phosphorus = 0 },
        .manure_g_per_m2 = .{ .carbon = 0, .nitrogen = 0, .phosphorus = 0 },
        .application_depth_m = 0,
        .band_row_width_m = 0,
        .fertilizer_formulation = 1,
        .plant_residue_type = 0,
        .manure_type = 0,
    };
    try applyEventNitrogen(&state, &litter, &reactive, 0, 1, 14, 0.25, &.{0.2}, event);
    try std.testing.expectApproxEqAbs(@as(f64, 2), litter.cells[0].ammonium_mol_n + litter.cells[0].urea_mol_n + litter.cells[0].nitrate_mol_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 8), state.soil[0].broadcast_ammonium_mol_n + state.soil[0].broadcast_ammonia_mol_n + state.soil[0].broadcast_urea_mol_n + state.soil[0].broadcast_nitrate_mol_n, 1e-14);
    try std.testing.expectEqual(@as(f64, 140), state.daily_nitrogen_input_g_n[0]);
    // formulation 1 is not nitrification-inhibited: the activity must stay
    // at its zero-initialized value.
    try std.testing.expectEqual(@as(f64, 0), reactive.initial_nitrification_inhibition_activity[0]);
}

// **A8a DISPOSITION: superseded structurally; the branch this module implements
// does not exist in production.** `redist.f:2790--2873` is the `ELSEIF(LS.EQ.1)`
// arm of the snowpack face loop: it is reached only when the outer
// `IF(VHCPW(LS).GT.VHCPWX)` at `:2417` *fails* for the top layer, i.e. there is
// no established snowpack, and then only when `XFLWS(1).NE.0.0` at `:2791`, i.e.
// snow is arriving. Its whole job is to accumulate arriving snow, water, vapor,
// ice, convective heat, ten solute carriers and (under `ISALTG.NE.0`) 41 salt
// and phosphorus species into the `T*` staging accumulators for a layer that is
// about to come into existence.
//
// The reason production has no analogue is that the branch is a consequence of
// legacy's staging design, not of the physics. Compare the sibling arm at
// `:2423--2435`, taken when the top layer *does* exist: it adds the same
// `XFLWS/XFLWW/XFLWV/XFLWI/XHFLWW` and then additionally subtracts the
// next-layer inflow `X*(LS2)` and the ground transfers
// `FLSWR/FLSW/FLSWH/FLSVR/FLSV/HFLSWR/HFLSW`. So the two arms differ only in
// which *outflows* are netted, never in the inflow. Production never nets: input
// is state_updateted by `snow_solute_transport.state_updateAtmosphericWater:117--143` and
// output is debited separately by `state_updateMeltWater:145--170`, each publishing
// atomically. With no shared `T*` accumulator to net into, the question "does the
// receiving layer already exist?" has no place to be asked, and both legacy arms
// collapse onto the same two unconditional calls.
//
// The two guards are likewise absorbed rather than dropped. The absent-layer
// condition `VHCPW(1) <= VHCPWX` becomes the `active` flag, which
// `state_updateAtmosphericWater:139--142` *sets* from the resulting inventory
// (`solid + liquid + ice > 0`) and which also repairs a zero density from
// `initial_snow_density_megagrams_per_m3` — production establishes the layer as a
// side effect of receiving mass instead of branching on its absence beforehand.
// The `XFLWS.NE.0` gate at `:2791` becomes vacuous for the same reason: adding
// zero input leaves the inventory, the recomputed
// `2.095/4.19/1.9274` heat capacity and the back-computed temperature unchanged,
// so the call is idempotent where legacy needed the test to avoid touching a
// nonexistent layer. Note this is a genuine identity here, unlike
// `snowpack_top_layer_drift_state_update`, which under zero input still overwrites
// `temperature_k`.
//
// The ten non-salt carriers at `:2797--2806` are owned too, though by a different
// route: `hourly_science_driver.zig:214--248` builds the per-species arriving mass
// from the weather header's precipitation pH, ammonium, nitrate and phosphate
// through `precipitation_nutrient_speciation`, adds the rain-gas equilibrium from
// `gas_transport.surfaceSolubilityWaterToAir`, folds in the irrigation share, and
// calls `snow_solute_transport.atmosphericInputG` into
// `snow_atmospheric_input_g`. Production therefore computes the arriving
// concentrations rather than accepting an `X*BLS` flux, which is why this module's
// `Inputs.surface_input.solute` has no producer.
//
// **The salt half is the known SALT-family gap, not a new finding.** The
// `IF(ISALTG.NE.0)` block at `:2829--2871` moves 41 species that production does
// not transport in snow at all, and Ottawa selects the static branch anyway, so
// this module's `.dynamic` mode has no configured caller. That is SALT-001 /
// SALT-002, and it is compounded by the flag conflation recorded at
// `state/site.zig:277--300`: Ottawa's site record says `ISALTG=1` while production
// drives every salt gate from `runscript.dynamic_plant_salts`, which is false. So
// legacy takes the dynamic arm here and production would take the static one.
// Nothing new is filed for it, and this module must not be bound as a way of
// closing it, because doing so would add a second writer of the top-layer
// inventory to buy only the salt species.
//
// snowpack surface input group of docs/traceability/a1b_snowpack_minimum_heat_capacity_unbound.md

const std = @import("std");

pub const SaltEquilibriumMode = enum {
    static,
    dynamic,
};

pub const SaltSpecies = enum {
    aluminum,
    iron,
    hydrogen,
    calcium,
    magnesium,
    sodium,
    potassium,
    hydroxide,
    sulfate,
    chloride,
    carbonate,
    bicarbonate,
    aluminum_monohydroxide,
    aluminum_dihydroxide,
    aluminum_trihydroxide,
    aluminum_tetrahydroxide,
    aluminum_sulfate,
    iron_monohydroxide,
    iron_dihydroxide,
    iron_trihydroxide,
    iron_tetrahydroxide,
    iron_sulfate,
    calcium_hydroxide,
    calcium_carbonate,
    calcium_bicarbonate,
    calcium_sulfate,
    magnesium_hydroxide,
    magnesium_carbonate,
    magnesium_bicarbonate,
    magnesium_sulfate,
    sodium_carbonate,
    sodium_sulfate,
    potassium_sulfate,
    phosphate,
    phosphoric_acid,
    iron_hydrogen_phosphate,
    iron_dihydrogen_phosphate,
    calcium_phosphate,
    calcium_hydrogen_phosphate,
    calcium_dihydrogen_phosphate,
    magnesium_hydrogen_phosphate,
};

pub const salt_species_count: usize =
    @typeInfo(SaltSpecies).@"enum".fields.len;

pub const WaterHeatFlux = struct {
    solid_snow_m3_per_step: f64 = 0,
    liquid_water_m3_per_step: f64 = 0,
    water_vapor_m3_per_step: f64 = 0,
    ice_m3_per_step: f64 = 0,
    convective_heat_megajoules_per_step: f64 = 0,
};

/// Non-salt carriers use the elemental gram basis tracked by ecosys.
pub const SoluteFlux = struct {
    carbon_dioxide_g_c_per_step: f64 = 0,
    methane_g_c_per_step: f64 = 0,
    oxygen_g_o_per_step: f64 = 0,
    dinitrogen_g_n_per_step: f64 = 0,
    nitrous_oxide_g_n_per_step: f64 = 0,
    ammonium_g_n_per_step: f64 = 0,
    ammonia_g_n_per_step: f64 = 0,
    nitrate_g_n_per_step: f64 = 0,
    hydrogen_phosphate_g_p_per_step: f64 = 0,
    dihydrogen_phosphate_g_p_per_step: f64 = 0,
};

pub const SurfaceInput = struct {
    water_heat: WaterHeatFlux,
    solute: SoluteFlux,
    /// Dynamic salt input [salt_species], mol per model step.
    salt_mol_per_step_by_species: []const f64,
};

pub const Inputs = struct {
    /// Current top snow-layer heat capacity, MJ K^-1.
    top_layer_heat_capacity_megajoules_per_k: f64,
    /// Snow-layer presence threshold, MJ K^-1.
    minimum_heat_capacity_megajoules_per_k: f64,
    surface_input: SurfaceInput,
};

pub const State = struct {
    top_layer_water_heat: WaterHeatFlux,
    top_layer_solute: SoluteFlux,
    /// Dynamic salt balance [salt_species], mol per model step.
    top_layer_salt_mol_per_step_by_species: []f64,
};

/// Dynamic-salt scratch is caller-owned; scalar candidate state remains local.
pub const Workspace = struct {
    top_layer_salt_mol_per_step_by_species: []f64,
};

/// Accounts surface inputs that establish a previously absent top snow layer.
///
/// Traceability: REDIST.F lines 2790--2873 (`TFLWS`--`TM1PBS`). The branch
/// runs only when the top layer is absent and incoming solid snow is nonzero.
/// Water/heat and ten non-salt carriers are always added; 41 salt species are
/// added only under dynamic equilibrium. State is state_updateted atomically after
/// all additions remain finite.
pub fn account(
    equilibrium_mode: SaltEquilibriumMode,
    inputs: Inputs,
    state: *State,
    workspace: Workspace,
) !void {
    try validateInputs(equilibrium_mode, inputs, state.*, workspace);
    if (inputs.top_layer_heat_capacity_megajoules_per_k >
        inputs.minimum_heat_capacity_megajoules_per_k)
    {
        return;
    }
    if (inputs.surface_input.water_heat.solid_snow_m3_per_step == 0) return;

    var water_heat = state.top_layer_water_heat;
    var solute = state.top_layer_solute;
    try addStruct(&water_heat, inputs.surface_input.water_heat);
    try addStruct(&solute, inputs.surface_input.solute);

    if (equilibrium_mode == .dynamic) {
        @memcpy(
            workspace.top_layer_salt_mol_per_step_by_species,
            state.top_layer_salt_mol_per_step_by_species,
        );
        for (
            workspace.top_layer_salt_mol_per_step_by_species,
            inputs.surface_input.salt_mol_per_step_by_species,
        ) |*candidate, contribution| {
            candidate.* = try add(candidate.*, contribution);
        }
    }

    state.top_layer_water_heat = water_heat;
    state.top_layer_solute = solute;
    if (equilibrium_mode == .dynamic) {
        @memcpy(
            state.top_layer_salt_mol_per_step_by_species,
            workspace.top_layer_salt_mol_per_step_by_species,
        );
    }
}

fn validateInputs(
    equilibrium_mode: SaltEquilibriumMode,
    inputs: Inputs,
    state: State,
    workspace: Workspace,
) !void {
    if (!std.math.isFinite(inputs.top_layer_heat_capacity_megajoules_per_k) or
        !std.math.isFinite(inputs.minimum_heat_capacity_megajoules_per_k))
    {
        return error.NonFiniteSnowpackSurfaceInput;
    }
    if (inputs.top_layer_heat_capacity_megajoules_per_k < 0 or
        inputs.minimum_heat_capacity_megajoules_per_k < 0)
    {
        return error.InvalidSnowpackHeatCapacity;
    }
    try validateStruct(inputs.surface_input.water_heat);
    try validateStruct(inputs.surface_input.solute);
    try validateStruct(state.top_layer_water_heat);
    try validateStruct(state.top_layer_solute);

    if (equilibrium_mode == .static) return;
    if (inputs.surface_input.salt_mol_per_step_by_species.len !=
        salt_species_count or
        state.top_layer_salt_mol_per_step_by_species.len !=
            salt_species_count or
        workspace.top_layer_salt_mol_per_step_by_species.len !=
            salt_species_count)
    {
        return error.SnowpackSurfaceSaltDimensionMismatch;
    }
    try validateFinite(inputs.surface_input.salt_mol_per_step_by_species);
    try validateFinite(state.top_layer_salt_mol_per_step_by_species);
    const scratch = workspace.top_layer_salt_mol_per_step_by_species;
    if (overlap(scratch, state.top_layer_salt_mol_per_step_by_species) or
        overlap(scratch, inputs.surface_input.salt_mol_per_step_by_species))
    {
        return error.SnowpackSurfaceSaltWorkspaceOverlap;
    }
}

fn validateStruct(value: anytype) !void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field|
        if (!std.math.isFinite(@field(value, field.name)))
            return error.NonFiniteSnowpackSurfaceInput;
}

fn validateFinite(values: []const f64) !void {
    for (values) |value|
        if (!std.math.isFinite(value))
            return error.NonFiniteSnowpackSurfaceInput;
}

fn addStruct(candidate: anytype, contribution: @TypeOf(candidate.*)) !void {
    inline for (@typeInfo(@TypeOf(candidate.*)).@"struct".fields) |field| {
        @field(candidate.*, field.name) = try add(
            @field(candidate.*, field.name),
            @field(contribution, field.name),
        );
    }
}

fn add(current: f64, contribution: f64) !f64 {
    const result = current + contribution;
    if (!std.math.isFinite(result))
        return error.NonFiniteSnowpackSurfaceResult;
    return result;
}

fn overlap(left: []const f64, right: []const f64) bool {
    if (left.len == 0 or right.len == 0) return false;
    const item_size = @sizeOf(f64);
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_bytes = std.math.mul(usize, left.len, item_size) catch return true;
    const right_bytes = std.math.mul(usize, right.len, item_size) catch return true;
    const left_end = std.math.add(usize, left_start, left_bytes) catch return true;
    const right_end = std.math.add(usize, right_start, right_bytes) catch return true;
    return left_start < right_end and right_start < left_end;
}

fn filled(comptime T: type, value: f64) T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field|
        @field(result, field.name) = value;
    return result;
}

fn expectStructValue(actual: anytype, expected: f64) !void {
    inline for (@typeInfo(@TypeOf(actual)).@"struct".fields) |field|
        try std.testing.expectEqual(expected, @field(actual, field.name));
}

test "absent top layer receives coupled dynamic surface input in source order" {
    const salt_input = [_]f64{3} ** salt_species_count;
    var salt_state = [_]f64{100} ** salt_species_count;
    var salt_scratch: [salt_species_count]f64 = undefined;
    var state = State{
        .top_layer_water_heat = filled(WaterHeatFlux, 100),
        .top_layer_solute = filled(SoluteFlux, 100),
        .top_layer_salt_mol_per_step_by_species = &salt_state,
    };

    try account(.dynamic, .{
        .top_layer_heat_capacity_megajoules_per_k = 0,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .surface_input = .{
            .water_heat = filled(WaterHeatFlux, 1),
            .solute = filled(SoluteFlux, 2),
            .salt_mol_per_step_by_species = &salt_input,
        },
    }, &state, .{
        .top_layer_salt_mol_per_step_by_species = &salt_scratch,
    });

    try expectStructValue(state.top_layer_water_heat, 101);
    try expectStructValue(state.top_layer_solute, 102);
    for (salt_state) |value| try std.testing.expectEqual(@as(f64, 103), value);
}

test "surface input changes equal every external input exactly" {
    const salt_input = [_]f64{7} ** salt_species_count;
    var salt_state = [_]f64{0} ** salt_species_count;
    var salt_scratch: [salt_species_count]f64 = undefined;
    var state = State{
        .top_layer_water_heat = .{},
        .top_layer_solute = .{},
        .top_layer_salt_mol_per_step_by_species = &salt_state,
    };
    const water_heat = WaterHeatFlux{
        .solid_snow_m3_per_step = 1,
        .liquid_water_m3_per_step = 2,
        .water_vapor_m3_per_step = 3,
        .ice_m3_per_step = 4,
        .convective_heat_megajoules_per_step = 5,
    };
    const solute = filled(SoluteFlux, 6);

    try account(.dynamic, .{
        .top_layer_heat_capacity_megajoules_per_k = 0,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .surface_input = .{
            .water_heat = water_heat,
            .solute = solute,
            .salt_mol_per_step_by_species = &salt_input,
        },
    }, &state, .{
        .top_layer_salt_mol_per_step_by_species = &salt_scratch,
    });

    try std.testing.expectEqualDeep(water_heat, state.top_layer_water_heat);
    try std.testing.expectEqualDeep(solute, state.top_layer_solute);
    for (salt_state, salt_input) |stored, external|
        try std.testing.expectEqual(external, stored);
}

test "source solid snow and absent-layer gates are exact" {
    const salt_input = [_]f64{3} ** salt_species_count;
    var salt_state = [_]f64{100} ** salt_species_count;
    var salt_scratch: [salt_species_count]f64 = undefined;
    var state = State{
        .top_layer_water_heat = filled(WaterHeatFlux, 100),
        .top_layer_solute = filled(SoluteFlux, 100),
        .top_layer_salt_mol_per_step_by_species = &salt_state,
    };
    const workspace = Workspace{
        .top_layer_salt_mol_per_step_by_species = &salt_scratch,
    };
    var surface_input = SurfaceInput{
        .water_heat = filled(WaterHeatFlux, 1),
        .solute = filled(SoluteFlux, 2),
        .salt_mol_per_step_by_species = &salt_input,
    };
    surface_input.water_heat.solid_snow_m3_per_step = 0;

    try account(.dynamic, .{
        .top_layer_heat_capacity_megajoules_per_k = 0,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .surface_input = surface_input,
    }, &state, workspace);
    try expectStructValue(state.top_layer_water_heat, 100);

    surface_input.water_heat.solid_snow_m3_per_step = 1;
    try account(.dynamic, .{
        .top_layer_heat_capacity_megajoules_per_k = 2,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .surface_input = surface_input,
    }, &state, workspace);
    try expectStructValue(state.top_layer_solute, 100);
    for (salt_state) |value| try std.testing.expectEqual(@as(f64, 100), value);
}

test "static salt mode still accounts water heat and non-salt solutes" {
    var state = State{
        .top_layer_water_heat = filled(WaterHeatFlux, 10),
        .top_layer_solute = filled(SoluteFlux, 20),
        .top_layer_salt_mol_per_step_by_species = &.{},
    };
    try account(.static, .{
        .top_layer_heat_capacity_megajoules_per_k = 0,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .surface_input = .{
            .water_heat = filled(WaterHeatFlux, 1),
            .solute = filled(SoluteFlux, 2),
            .salt_mol_per_step_by_species = &.{},
        },
    }, &state, .{ .top_layer_salt_mol_per_step_by_species = &.{} });
    try expectStructValue(state.top_layer_water_heat, 11);
    try expectStructValue(state.top_layer_solute, 22);
}

test "late invalid input and overflow preserve coupled state atomically" {
    var salt_input = [_]f64{1} ** salt_species_count;
    salt_input[salt_species_count - 1] = std.math.nan(f64);
    var salt_state = [_]f64{3} ** salt_species_count;
    var salt_scratch: [salt_species_count]f64 = undefined;
    var state = State{
        .top_layer_water_heat = filled(WaterHeatFlux, 3),
        .top_layer_solute = filled(SoluteFlux, 3),
        .top_layer_salt_mol_per_step_by_species = &salt_state,
    };
    const workspace = Workspace{
        .top_layer_salt_mol_per_step_by_species = &salt_scratch,
    };

    try std.testing.expectError(
        error.NonFiniteSnowpackSurfaceInput,
        account(.dynamic, .{
            .top_layer_heat_capacity_megajoules_per_k = 0,
            .minimum_heat_capacity_megajoules_per_k = 1,
            .surface_input = .{
                .water_heat = filled(WaterHeatFlux, 1),
                .solute = filled(SoluteFlux, 1),
                .salt_mol_per_step_by_species = &salt_input,
            },
        }, &state, workspace),
    );
    try expectStructValue(state.top_layer_water_heat, 3);
    try expectStructValue(state.top_layer_solute, 3);

    salt_input[salt_species_count - 1] = 0;
    state.top_layer_water_heat = filled(
        WaterHeatFlux,
        std.math.floatMax(f64),
    );
    try std.testing.expectError(
        error.NonFiniteSnowpackSurfaceResult,
        account(.dynamic, .{
            .top_layer_heat_capacity_megajoules_per_k = 0,
            .minimum_heat_capacity_megajoules_per_k = 1,
            .surface_input = .{
                .water_heat = filled(WaterHeatFlux, std.math.floatMax(f64)),
                .solute = filled(SoluteFlux, 1),
                .salt_mol_per_step_by_species = &salt_input,
            },
        }, &state, workspace),
    );
    try expectStructValue(
        state.top_layer_water_heat,
        std.math.floatMax(f64),
    );
    try expectStructValue(state.top_layer_solute, 3);
}

test "dynamic salt shape and workspace alias errors precede mutation" {
    const salt_input = [_]f64{1} ** salt_species_count;
    var salt_state = [_]f64{5} ** salt_species_count;
    var state = State{
        .top_layer_water_heat = filled(WaterHeatFlux, 5),
        .top_layer_solute = filled(SoluteFlux, 5),
        .top_layer_salt_mol_per_step_by_species = &salt_state,
    };
    const inputs = Inputs{
        .top_layer_heat_capacity_megajoules_per_k = 0,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .surface_input = .{
            .water_heat = filled(WaterHeatFlux, 1),
            .solute = filled(SoluteFlux, 1),
            .salt_mol_per_step_by_species = &salt_input,
        },
    };

    try std.testing.expectError(
        error.SnowpackSurfaceSaltWorkspaceOverlap,
        account(.dynamic, inputs, &state, .{
            .top_layer_salt_mol_per_step_by_species = &salt_state,
        }),
    );
    try expectStructValue(state.top_layer_water_heat, 5);

    var short_scratch: [salt_species_count - 1]f64 = undefined;
    try std.testing.expectError(
        error.SnowpackSurfaceSaltDimensionMismatch,
        account(.dynamic, inputs, &state, .{
            .top_layer_salt_mol_per_step_by_species = &short_scratch,
        }),
    );
    try expectStructValue(state.top_layer_solute, 5);
}

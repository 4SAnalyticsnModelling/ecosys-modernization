const std = @import("std");
const builtin = @import("builtin");
const SoilProperties = @import("../../soil/water/solver_properties.zig").State;
const SoilThermal = @import("../../soil/heat/thermal.zig").State;
const retention = @import("../../soil/water/retention.zig");
const ReactionParameters = @import("../../soil/solute/chemistry_state.zig").ReactionParameters;
const ExchangeSelectivity = @import("../../soil/solute/cation_exchange.zig").Selectivity;

pub const solver_field_count = @typeInfo(SolverField).@"enum".fields.len;
pub const thermal_field_count = @typeInfo(ThermalField).@"enum".fields.len;

pub const SolverField = enum {
    lateral_saturated_hydraulic_conductivity_m_per_h,
    matrix_bulk_volume_m3,
    layer_volume_m3,
    layer_thickness_m,
    initial_layer_thickness_m,
    layer_midpoint_depth_m,
    layer_bottom_depth_m,
    bulk_density_megagrams_per_m3,
    reference_bulk_density_megagrams_per_m3,
    sand_mass_fraction,
    silt_mass_fraction,
    clay_mass_fraction,
    sand_mass_megagrams,
    silt_mass_megagrams,
    clay_mass_megagrams,
    total_organic_carbon_g_per_megagram,
    cation_exchange_capacity_mol_per_megagram,
    anion_exchange_capacity_mol_per_megagram,
    cation_exchange_capacity_mol,
    anion_exchange_capacity_mol,
    porosity_fraction,
    micropore_fraction,
    macropore_fraction,
    rock_fraction,
    supplied_field_capacity_fraction,
    supplied_wilting_point_fraction,
    field_capacity_water_potential_megapascal,
    wilting_point_water_potential_megapascal,
    supplied_vertical_saturated_hydraulic_conductivity_m_per_h,
    supplied_lateral_saturated_hydraulic_conductivity_m_per_h,
    supplied_lateral_conductivity_m2_per_h_megapascal,
    van_genuchten_inflection_pressure_head_m,
    charcoal_retention_increment_fraction,
    previous_charcoal_carbon_g_c,
    field_capacity_fraction,
    wilting_point_fraction,
    saturation_water_potential_megapascal,
    rainfall_conductivity_multiplier,
    saturated_lateral_conductivity_m2_per_h_megapascal,
};

pub const ThermalField = enum {
    layer_volume_m3,
    layer_thickness_m,
    porosity_fraction,
    dry_solid_heat_capacity_megajoules_per_m3_k,
    solid_thermal_conductivity_numerator_m_megajoules_per_h_k,
    solid_thermal_conductivity_denominator,
    total_heat_capacity_megajoules_per_m3_k,
    thermal_conductivity_m_megajoules_per_h_k,
};

pub const View = struct {
    soil_properties: *const SoilProperties,
    soil_thermal: *const SoilThermal,
    /// REDIST mixes five of the six Gapon coefficients and commits them into
    /// the per-layer reaction parameters. They are persistent science state,
    /// not runscript constants, so an accepted post-tillage checkpoint must
    /// carry the complete selectivity tuple (including the invariant H term)
    /// and the reaction network's capacity mirror.
    soil_chemistry_layer_parameters: []const ReactionParameters,
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    solver_fields: [solver_field_count][]f64,
    thermal_fields: [thermal_field_count][]f64,
    retention_curve: []retention.ResolvedCurve,
    mualem_van_genuchten_parameters: []retention.MualemVanGenuchtenParameters,
    reaction_cation_exchange_capacity_mol_charge_per_megagram: []f64,
    exchange_selectivity: []ExchangeSelectivity,

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.exchange_selectivity);
        self.allocator.free(self.reaction_cation_exchange_capacity_mol_charge_per_megagram);
        self.allocator.free(self.mualem_van_genuchten_parameters);
        self.allocator.free(self.retention_curve);
        for (self.thermal_fields) |values| self.allocator.free(values);
        for (self.solver_fields) |values| self.allocator.free(values);
        self.* = undefined;
    }

    pub fn restoreInto(
        self: Snapshot,
        soil_properties: *SoilProperties,
        soil_thermal: *SoilThermal,
        soil_chemistry_layer_parameters: []ReactionParameters,
    ) !void {
        try validateTargetLayout(.{
            .soil_properties = soil_properties,
            .soil_thermal = soil_thermal,
            .soil_chemistry_layer_parameters = soil_chemistry_layer_parameters,
        });
        try self.validate();
        inline for (@typeInfo(SolverField).@"enum".fields, 0..) |field, index|
            @memcpy(
                mutableSolverValues(soil_properties, @enumFromInt(field.value)),
                self.solver_fields[index],
            );
        inline for (@typeInfo(ThermalField).@"enum".fields, 0..) |field, index|
            @memcpy(
                mutableThermalValues(soil_thermal, @enumFromInt(field.value)),
                self.thermal_fields[index],
            );
        @memcpy(soil_properties.retention_curve, self.retention_curve);
        @memcpy(soil_properties.mualem_van_genuchten_parameters, self.mualem_van_genuchten_parameters);
        for (
            soil_chemistry_layer_parameters,
            self.reaction_cation_exchange_capacity_mol_charge_per_megagram,
            self.exchange_selectivity,
        ) |*parameters, capacity, selectivity| {
            parameters.cation_exchange_capacity_mol_charge_per_megagram = capacity;
            parameters.cation_exchange_parameters.selectivity = selectivity;
        }
        try validateView(.{
            .soil_properties = soil_properties,
            .soil_thermal = soil_thermal,
            .soil_chemistry_layer_parameters = soil_chemistry_layer_parameters,
        });
    }

    pub fn validate(self: Snapshot) !void {
        if (self.layer_count == 0)
            return error.SoilRuntimeCheckpointDimensionMismatch;
        for (self.solver_fields) |values| {
            if (values.len != self.layer_count)
                return error.SoilRuntimeCheckpointDimensionMismatch;
            try validateFinite(values);
        }
        for (self.thermal_fields) |values| {
            if (values.len != self.layer_count)
                return error.SoilRuntimeCheckpointDimensionMismatch;
            try validateFinite(values);
        }
        if (self.retention_curve.len != self.layer_count or
            self.mualem_van_genuchten_parameters.len != self.layer_count or
            self.reaction_cation_exchange_capacity_mol_charge_per_megagram.len != self.layer_count or
            self.exchange_selectivity.len != self.layer_count)
            return error.SoilRuntimeCheckpointDimensionMismatch;
        try validateNonnegativeFinite(
            self.reaction_cation_exchange_capacity_mol_charge_per_megagram,
        );
        try validateExchangeSelectivity(self.exchange_selectivity);
        for (self.retention_curve, self.mualem_van_genuchten_parameters, 0..) |curve, mualem, index| {
            try validateResolvedCurve(curve);
            try mualem.validate();
            if (curve.porosity_fraction != self.solver_fields[@intFromEnum(SolverField.porosity_fraction)][index] or
                curve.curve.field_capacity_fraction != self.solver_fields[@intFromEnum(SolverField.field_capacity_fraction)][index] or
                curve.curve.wilting_point_fraction != self.solver_fields[@intFromEnum(SolverField.wilting_point_fraction)][index] or
                curve.curve.saturation_water_potential_megapascal != self.solver_fields[@intFromEnum(SolverField.saturation_water_potential_megapascal)][index])
                return error.InvalidSoilRuntimeCheckpointState;
        }
        const solver_volume = self.solver_fields[
            @intFromEnum(SolverField.layer_volume_m3)
        ];
        const matrix_volume = self.solver_fields[
            @intFromEnum(SolverField.matrix_bulk_volume_m3)
        ];
        const density = self.solver_fields[
            @intFromEnum(SolverField.bulk_density_megagrams_per_m3)
        ];
        const solver_porosity = self.solver_fields[
            @intFromEnum(SolverField.porosity_fraction)
        ];
        const solver_thickness = self.solver_fields[
            @intFromEnum(SolverField.layer_thickness_m)
        ];
        const initial_thickness = self.solver_fields[
            @intFromEnum(SolverField.initial_layer_thickness_m)
        ];
        const reference_density = self.solver_fields[
            @intFromEnum(SolverField.reference_bulk_density_megagrams_per_m3)
        ];
        const thermal_volume = self.thermal_fields[
            @intFromEnum(ThermalField.layer_volume_m3)
        ];
        const thermal_thickness = self.thermal_fields[
            @intFromEnum(ThermalField.layer_thickness_m)
        ];
        const thermal_porosity = self.thermal_fields[
            @intFromEnum(ThermalField.porosity_fraction)
        ];
        const dry_heat_capacity = self.thermal_fields[
            @intFromEnum(ThermalField.dry_solid_heat_capacity_megajoules_per_m3_k)
        ];
        const total_heat_capacity = self.thermal_fields[
            @intFromEnum(ThermalField.total_heat_capacity_megajoules_per_m3_k)
        ];
        const conductivity = self.thermal_fields[
            @intFromEnum(ThermalField.thermal_conductivity_m_megajoules_per_h_k)
        ];
        for (0..self.layer_count) |index| {
            if (solver_volume[index] <= 0 or matrix_volume[index] < 0 or
                matrix_volume[index] > solver_volume[index] or
                density[index] < 0 or reference_density[index] <= 0 or
                solver_porosity[index] < 0 or solver_porosity[index] > 1 or
                solver_thickness[index] <= 0 or initial_thickness[index] <= 0 or
                thermal_volume[index] <= 0 or thermal_thickness[index] <= 0 or
                thermal_porosity[index] < 0 or thermal_porosity[index] > 1 or
                dry_heat_capacity[index] < 0 or total_heat_capacity[index] < 0 or
                conductivity[index] < 0)
                return error.InvalidSoilRuntimeCheckpointState;
            const micropore = self.solver_fields[@intFromEnum(SolverField.micropore_fraction)][index];
            const macropore = self.solver_fields[@intFromEnum(SolverField.macropore_fraction)][index];
            const rock = self.solver_fields[@intFromEnum(SolverField.rock_fraction)][index];
            const supplied_fc = self.solver_fields[@intFromEnum(SolverField.supplied_field_capacity_fraction)][index];
            const supplied_wp = self.solver_fields[@intFromEnum(SolverField.supplied_wilting_point_fraction)][index];
            const field_potential = self.solver_fields[@intFromEnum(SolverField.field_capacity_water_potential_megapascal)][index];
            const wilting_potential = self.solver_fields[@intFromEnum(SolverField.wilting_point_water_potential_megapascal)][index];
            const previous_charcoal = self.solver_fields[@intFromEnum(SolverField.previous_charcoal_carbon_g_c)][index];
            const inflection = self.solver_fields[@intFromEnum(SolverField.van_genuchten_inflection_pressure_head_m)][index];
            if (micropore < 0 or micropore > 1 or macropore < 0 or macropore >= 1 or
                !validAdditiveRock(rock) or previous_charcoal < 0 or inflection > 0 or
                field_potential >= 0 or wilting_potential >= field_potential or
                (supplied_fc >= 0 and supplied_fc > 1) or
                (supplied_wp >= 0 and supplied_wp > 1))
                return error.InvalidSoilRuntimeCheckpointState;
        }
    }
};

pub fn write(writer: anytype, view: View) !void {
    try validateView(view);
    try writer.writeInt(u64, @intCast(view.soil_properties.layer_count), .little);
    inline for (@typeInfo(SolverField).@"enum".fields) |field|
        try writeF64Slice(
            writer,
            solverValues(view.soil_properties, @enumFromInt(field.value)),
        );
    try writeResolvedCurveSlice(writer, view.soil_properties.retention_curve);
    try writeMualemSlice(writer, view.soil_properties.mualem_van_genuchten_parameters);
    inline for (@typeInfo(ThermalField).@"enum".fields) |field|
        try writeF64Slice(
            writer,
            thermalValues(view.soil_thermal, @enumFromInt(field.value)),
        );
    for (view.soil_chemistry_layer_parameters) |parameters| {
        try writeF64(
            writer,
            parameters.cation_exchange_capacity_mol_charge_per_megagram,
        );
        try writeExchangeSelectivity(
            writer,
            parameters.cation_exchange_parameters.selectivity,
        );
    }
}

pub fn read(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    expected_layer_count: usize,
) !Snapshot {
    const layer_count_u64 = try reader.takeInt(u64, .little);
    if (layer_count_u64 != expected_layer_count)
        return error.SoilRuntimeCheckpointDimensionMismatch;
    var result: Snapshot = .{
        .allocator = allocator,
        .layer_count = expected_layer_count,
        .solver_fields = undefined,
        .thermal_fields = undefined,
        .retention_curve = try allocator.alloc(retention.ResolvedCurve, expected_layer_count),
        .mualem_van_genuchten_parameters = undefined,
        .reaction_cation_exchange_capacity_mol_charge_per_megagram = undefined,
        .exchange_selectivity = undefined,
    };
    errdefer allocator.free(result.retention_curve);
    result.mualem_van_genuchten_parameters = try allocator.alloc(retention.MualemVanGenuchtenParameters, expected_layer_count);
    errdefer allocator.free(result.mualem_van_genuchten_parameters);
    result.exchange_selectivity = try allocator.alloc(ExchangeSelectivity, expected_layer_count);
    errdefer allocator.free(result.exchange_selectivity);
    result.reaction_cation_exchange_capacity_mol_charge_per_megagram = try allocator.alloc(f64, expected_layer_count);
    errdefer allocator.free(result.reaction_cation_exchange_capacity_mol_charge_per_megagram);
    var solver_allocated: usize = 0;
    var thermal_allocated: usize = 0;
    errdefer {
        for (result.thermal_fields[0..thermal_allocated]) |values|
            allocator.free(values);
        for (result.solver_fields[0..solver_allocated]) |values|
            allocator.free(values);
    }
    for (&result.solver_fields) |*values| {
        values.* = try allocator.alloc(f64, expected_layer_count);
        solver_allocated += 1;
        try readF64Slice(reader, values.*);
    }
    try readResolvedCurveSlice(reader, result.retention_curve);
    try readMualemSlice(reader, result.mualem_van_genuchten_parameters);
    for (&result.thermal_fields) |*values| {
        values.* = try allocator.alloc(f64, expected_layer_count);
        thermal_allocated += 1;
        try readF64Slice(reader, values.*);
    }
    for (
        result.reaction_cation_exchange_capacity_mol_charge_per_megagram,
        result.exchange_selectivity,
    ) |*capacity, *selectivity| {
        capacity.* = try readF64(reader);
        selectivity.* = try readExchangeSelectivity(reader);
    }
    try result.validate();
    return result;
}

pub fn validateView(view: View) !void {
    try validateTargetLayout(view);
    inline for (@typeInfo(SolverField).@"enum".fields) |field|
        try validateFinite(
            solverValues(view.soil_properties, @enumFromInt(field.value)),
        );
    inline for (@typeInfo(ThermalField).@"enum".fields) |field|
        try validateFinite(
            thermalValues(view.soil_thermal, @enumFromInt(field.value)),
        );
    for (view.soil_chemistry_layer_parameters, 0..) |parameters, index|
        if (!std.math.isFinite(parameters.cation_exchange_capacity_mol_charge_per_megagram) or
            parameters.cation_exchange_capacity_mol_charge_per_megagram < 0)
        {
            if (!builtin.is_test) std.log.err(
                "invalid soil runtime checkpoint chemistry capacity: layer={d} cec_mol_charge_per_megagram={e}",
                .{ index, parameters.cation_exchange_capacity_mol_charge_per_megagram },
            );
            return error.InvalidSoilRuntimeCheckpointState;
        };
    for (view.soil_chemistry_layer_parameters, 0..) |parameters, index|
        validateExchangeSelectivityValue(
            parameters.cation_exchange_parameters.selectivity,
        ) catch |err| {
            if (!builtin.is_test) std.log.err(
                "invalid soil runtime checkpoint exchange selectivity: layer={d} error={s}",
                .{ index, @errorName(err) },
            );
            return err;
        };
    for (view.soil_properties.retention_curve, view.soil_properties.mualem_van_genuchten_parameters, 0..) |curve, mualem, index| {
        validateResolvedCurve(curve) catch |err| {
            if (!builtin.is_test) std.log.err(
                "invalid soil runtime checkpoint retention curve: layer={d} error={s}",
                .{ index, @errorName(err) },
            );
            return err;
        };
        mualem.validate() catch |err| {
            if (!builtin.is_test) std.log.err(
                "invalid soil runtime checkpoint Mualem parameters: layer={d} error={s}",
                .{ index, @errorName(err) },
            );
            return err;
        };
        if (curve.porosity_fraction != view.soil_properties.porosity_fraction[index] or
            curve.curve.field_capacity_fraction != view.soil_properties.field_capacity_fraction[index] or
            curve.curve.wilting_point_fraction != view.soil_properties.wilting_point_fraction[index] or
            curve.curve.saturation_water_potential_megapascal != view.soil_properties.saturation_water_potential_megapascal[index])
        {
            if (!builtin.is_test) std.log.err(
                "inconsistent soil runtime checkpoint hydraulic mirrors: layer={d} curve_porosity={e} scalar_porosity={e} curve_field_capacity={e} scalar_field_capacity={e} curve_wilting_point={e} scalar_wilting_point={e} curve_saturation_potential_mpa={e} scalar_saturation_potential_mpa={e}",
                .{ index, curve.porosity_fraction, view.soil_properties.porosity_fraction[index], curve.curve.field_capacity_fraction, view.soil_properties.field_capacity_fraction[index], curve.curve.wilting_point_fraction, view.soil_properties.wilting_point_fraction[index], curve.curve.saturation_water_potential_megapascal, view.soil_properties.saturation_water_potential_megapascal[index] },
            );
            return error.InvalidSoilRuntimeCheckpointState;
        }
    }
    for (view.soil_properties.layer_volume_m3, 0..) |volume, index| {
        const matrix_volume = view.soil_properties.matrix_bulk_volume_m3[index];
        const density = view.soil_properties.bulk_density_megagrams_per_m3[index];
        const porosity = view.soil_properties.porosity_fraction[index];
        if (volume <= 0 or matrix_volume < 0 or matrix_volume > volume or
            density < 0 or porosity < 0 or porosity > 1 or
            view.soil_properties.layer_thickness_m[index] <= 0 or
            view.soil_properties.initial_layer_thickness_m[index] <= 0 or
            view.soil_properties.reference_bulk_density_megagrams_per_m3[index] <= 0 or
            view.soil_thermal.layer_volume_m3[index] <= 0 or
            view.soil_thermal.layer_thickness_m[index] <= 0 or
            view.soil_thermal.porosity_fraction[index] < 0 or
            view.soil_thermal.porosity_fraction[index] > 1 or
            view.soil_thermal.dry_solid_heat_capacity_megajoules_per_m3_k[index] < 0 or
            view.soil_thermal.total_heat_capacity_megajoules_per_m3_k[index] < 0 or
            view.soil_thermal.thermal_conductivity_m_megajoules_per_h_k[index] < 0)
        {
            if (!builtin.is_test) std.log.err(
                "invalid soil runtime checkpoint geometry or thermal state: layer={d} layer_volume_m3={e} matrix_volume_m3={e} bulk_density={e} porosity={e} thickness_m={e} initial_thickness_m={e} reference_bulk_density={e} thermal_volume_m3={e} thermal_thickness_m={e} thermal_porosity={e} dry_heat_capacity={e} total_heat_capacity={e} thermal_conductivity={e}",
                .{ index, volume, matrix_volume, density, porosity, view.soil_properties.layer_thickness_m[index], view.soil_properties.initial_layer_thickness_m[index], view.soil_properties.reference_bulk_density_megagrams_per_m3[index], view.soil_thermal.layer_volume_m3[index], view.soil_thermal.layer_thickness_m[index], view.soil_thermal.porosity_fraction[index], view.soil_thermal.dry_solid_heat_capacity_megajoules_per_m3_k[index], view.soil_thermal.total_heat_capacity_megajoules_per_m3_k[index], view.soil_thermal.thermal_conductivity_m_megajoules_per_h_k[index] },
            );
            return error.InvalidSoilRuntimeCheckpointState;
        }
        const micropore = view.soil_properties.micropore_fraction[index];
        const macropore = view.soil_properties.macropore_fraction[index];
        const rock = view.soil_properties.rock_fraction[index];
        const supplied_fc = view.soil_properties.supplied_field_capacity_fraction[index];
        const supplied_wp = view.soil_properties.supplied_wilting_point_fraction[index];
        if (micropore < 0 or micropore > 1 or macropore < 0 or macropore >= 1 or
            !validAdditiveRock(rock) or view.soil_properties.previous_charcoal_carbon_g_c[index] < 0 or
            view.soil_properties.van_genuchten_inflection_pressure_head_m[index] > 0 or
            view.soil_properties.field_capacity_water_potential_megapascal[index] >= 0 or
            view.soil_properties.wilting_point_water_potential_megapascal[index] >= view.soil_properties.field_capacity_water_potential_megapascal[index] or
            (supplied_fc >= 0 and supplied_fc > 1) or
            (supplied_wp >= 0 and supplied_wp > 1))
        {
            if (!builtin.is_test) std.log.err(
                "invalid soil runtime checkpoint material controls: layer={d} micropore={e} macropore={e} rock={e} previous_charcoal_g_c={e} vg_inflection_head_m={e} field_capacity_potential_mpa={e} wilting_potential_mpa={e} supplied_field_capacity={e} supplied_wilting_point={e}",
                .{ index, micropore, macropore, rock, view.soil_properties.previous_charcoal_carbon_g_c[index], view.soil_properties.van_genuchten_inflection_pressure_head_m[index], view.soil_properties.field_capacity_water_potential_megapascal[index], view.soil_properties.wilting_point_water_potential_megapascal[index], supplied_fc, supplied_wp },
            );
            return error.InvalidSoilRuntimeCheckpointState;
        }
    }
}

/// Checks only the destination allocation/layout needed for an overwrite.
/// Rollback must not reject a destination because the failed attempt left its
/// numerical values invalid; the validated snapshot is authoritative.
pub fn validateTargetLayout(view: View) !void {
    const layer_count = view.soil_properties.layer_count;
    try validateDimensions(view, layer_count);
    if (view.soil_properties.retention_curve.len != layer_count or
        view.soil_properties.mualem_van_genuchten_parameters.len != layer_count or
        view.soil_chemistry_layer_parameters.len != layer_count)
        return error.SoilRuntimeCheckpointDimensionMismatch;
}

fn validateDimensions(view: View, layer_count: usize) !void {
    if (layer_count == 0 or
        view.soil_thermal.cell_count == 0 or
        view.soil_thermal.soil_layer_capacity == 0 or
        view.soil_thermal.cell_count * view.soil_thermal.soil_layer_capacity !=
            layer_count)
        return error.SoilRuntimeCheckpointDimensionMismatch;
    inline for (@typeInfo(SolverField).@"enum".fields) |field|
        if (solverValues(view.soil_properties, @enumFromInt(field.value)).len !=
            layer_count)
            return error.SoilRuntimeCheckpointDimensionMismatch;
    inline for (@typeInfo(ThermalField).@"enum".fields) |field|
        if (thermalValues(view.soil_thermal, @enumFromInt(field.value)).len !=
            layer_count)
            return error.SoilRuntimeCheckpointDimensionMismatch;
}

fn solverValues(state: *const SoilProperties, field: SolverField) []const f64 {
    return switch (field) {
        inline else => |selected| @field(state, @tagName(selected)),
    };
}

fn mutableSolverValues(state: *SoilProperties, field: SolverField) []f64 {
    return switch (field) {
        inline else => |selected| @field(state, @tagName(selected)),
    };
}

fn thermalValues(state: *const SoilThermal, field: ThermalField) []const f64 {
    return switch (field) {
        inline else => |selected| @field(state, @tagName(selected)),
    };
}

fn mutableThermalValues(state: *SoilThermal, field: ThermalField) []f64 {
    return switch (field) {
        inline else => |selected| @field(state, @tagName(selected)),
    };
}

fn writeF64Slice(writer: anytype, values: []const f64) !void {
    for (values) |value| {
        if (!std.math.isFinite(value))
            return error.NonFiniteSoilRuntimeCheckpoint;
        try writer.writeInt(u64, @bitCast(value), .little);
    }
}

fn readF64Slice(reader: *std.Io.Reader, values: []f64) !void {
    for (values) |*value| {
        value.* = @bitCast(try reader.takeInt(u64, .little));
        if (!std.math.isFinite(value.*))
            return error.NonFiniteSoilRuntimeCheckpoint;
    }
}

fn writeResolvedCurveSlice(writer: anytype, values: []const retention.ResolvedCurve) !void {
    for (values) |value| {
        try writeF64(writer, value.porosity_fraction);
        inline for (@typeInfo(retention.Curve).@"struct".fields) |field|
            try writeF64(writer, @field(value.curve, field.name));
    }
}

fn readResolvedCurveSlice(reader: *std.Io.Reader, values: []retention.ResolvedCurve) !void {
    for (values) |*value| {
        value.porosity_fraction = try readF64(reader);
        inline for (@typeInfo(retention.Curve).@"struct".fields) |field|
            @field(value.curve, field.name) = try readF64(reader);
    }
}

fn writeMualemSlice(writer: anytype, values: []const retention.MualemVanGenuchtenParameters) !void {
    for (values) |value| {
        inline for (@typeInfo(retention.MualemVanGenuchtenParameters).@"struct".fields) |field|
            try writeF64(writer, @field(value, field.name));
    }
}

fn readMualemSlice(reader: *std.Io.Reader, values: []retention.MualemVanGenuchtenParameters) !void {
    for (values) |*value| {
        inline for (@typeInfo(retention.MualemVanGenuchtenParameters).@"struct".fields) |field|
            @field(value, field.name) = try readF64(reader);
    }
}

fn writeF64(writer: anytype, value: f64) !void {
    if (!std.math.isFinite(value)) return error.NonFiniteSoilRuntimeCheckpoint;
    try writer.writeInt(u64, @bitCast(value), .little);
}

fn readF64(reader: *std.Io.Reader) !f64 {
    const value: f64 = @bitCast(try reader.takeInt(u64, .little));
    if (!std.math.isFinite(value)) return error.NonFiniteSoilRuntimeCheckpoint;
    return value;
}

fn writeExchangeSelectivity(writer: anytype, value: ExchangeSelectivity) !void {
    inline for (@typeInfo(ExchangeSelectivity).@"struct".fields) |field|
        try writeF64(writer, @field(value, field.name));
}

fn readExchangeSelectivity(reader: *std.Io.Reader) !ExchangeSelectivity {
    var value: ExchangeSelectivity = undefined;
    inline for (@typeInfo(ExchangeSelectivity).@"struct".fields) |field|
        @field(value, field.name) = try readF64(reader);
    return value;
}

fn validateExchangeSelectivity(values: []const ExchangeSelectivity) !void {
    for (values) |value| try validateExchangeSelectivityValue(value);
}

fn validateExchangeSelectivityValue(value: ExchangeSelectivity) !void {
    inline for (@typeInfo(ExchangeSelectivity).@"struct".fields) |field|
        if (!std.math.isFinite(@field(value, field.name)) or
            @field(value, field.name) < 0)
            return error.InvalidSoilRuntimeCheckpointState;
}

fn validateResolvedCurve(curve: retention.ResolvedCurve) !void {
    inline for (@typeInfo(retention.Curve).@"struct".fields) |field|
        if (!std.math.isFinite(@field(curve.curve, field.name)))
            return error.NonFiniteSoilRuntimeCheckpoint;
    if (!std.math.isFinite(curve.porosity_fraction) or
        curve.porosity_fraction <= 0 or curve.porosity_fraction > 1 or
        curve.curve.wilting_point_fraction <= 0 or
        curve.curve.field_capacity_fraction <= curve.curve.wilting_point_fraction or
        curve.curve.field_capacity_fraction >= curve.porosity_fraction or
        curve.curve.saturation_water_potential_megapascal >= 0 or
        curve.curve.field_capacity_water_potential_megapascal >= 0 or
        curve.curve.wilting_point_water_potential_megapascal >= curve.curve.field_capacity_water_potential_megapascal)
        return error.InvalidSoilRuntimeCheckpointState;
}

fn validateFinite(values: []const f64) !void {
    for (values) |value| if (!std.math.isFinite(value))
        return error.NonFiniteSoilRuntimeCheckpoint;
}

fn validateNonnegativeFinite(values: []const f64) !void {
    for (values) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidSoilRuntimeCheckpointState;
}

// Despite its historical name, REDIST ROCK is an additive extensive layer
// owner. Deposition can therefore make it greater than one; only finite,
// nonnegative values are physically admissible.
fn validAdditiveRock(value: f64) bool {
    return std.math.isFinite(value) and value >= 0;
}

test "checkpoint accepts additive REDIST ROCK above one" {
    try std.testing.expect(validAdditiveRock(1.3));
    try std.testing.expect(validAdditiveRock(0));
    try std.testing.expect(!validAdditiveRock(-0.1));
    try std.testing.expect(!validAdditiveRock(std.math.nan(f64)));
}

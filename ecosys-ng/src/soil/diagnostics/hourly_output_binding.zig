const std = @import("std");
const gas = @import("../gas/transport.zig");
const AqueousState = @import("../solute/aqueous_network.zig").State;

/// Componentwise view of the accepted atmospheric gas boundary for one
/// horizontal cell. `total_exchange_g` retains the legacy litter-first
/// reduction order used by HOUR1/OUTSH; the split terms are diagnostics and do
/// not alter the value published to output or conservation ledgers.
pub const GasBoundaryExchangeComponents = struct {
    soil_exchange_g: f64,
    litter_exchange_g: f64,
    total_exchange_g: f64,

    pub fn splitClosureResidualG(self: GasBoundaryExchangeComponents) f64 {
        return self.total_exchange_g -
            (self.soil_exchange_g + self.litter_exchange_g);
    }
};

pub fn gasBoundaryExchangeComponentsG(
    soil_flux_g_per_h: []const f64,
    litter_flux_g_per_h: []const f64,
    first_soil_layer: usize,
    soil_layer_count: usize,
    litter_cell: usize,
    species: gas.Species,
) !GasBoundaryExchangeComponents {
    if (soil_flux_g_per_h.len % gas.species_count != 0 or
        litter_flux_g_per_h.len % gas.species_count != 0)
        return error.GasOutputBoundaryDimensionMismatch;
    const soil_cells = soil_flux_g_per_h.len / gas.species_count;
    const litter_cells = litter_flux_g_per_h.len / gas.species_count;
    if (first_soil_layer > soil_cells or
        soil_layer_count > soil_cells - first_soil_layer or
        litter_cell >= litter_cells)
        return error.GasOutputBoundaryDimensionMismatch;

    const species_index = @intFromEnum(species);
    const litter_exchange_g =
        litter_flux_g_per_h[litter_cell * gas.species_count + species_index];
    var soil_exchange_g: f64 = 0;
    var total_exchange_g = litter_exchange_g;
    for (first_soil_layer..first_soil_layer + soil_layer_count) |layer| {
        const exchange_g =
            soil_flux_g_per_h[layer * gas.species_count + species_index];
        soil_exchange_g += exchange_g;
        total_exchange_g += exchange_g;
    }
    if (!std.math.isFinite(total_exchange_g))
        return error.NonFiniteGasOutputBoundaryExchange;
    return .{
        .soil_exchange_g = soil_exchange_g,
        .litter_exchange_g = litter_exchange_g,
        .total_exchange_g = total_exchange_g,
    };
}

/// Sums accepted soil-profile and surface-litter atmospheric exchange for one
/// runtime grid cell. The sign is unchanged from TRNSFR/REDIST: positive mass
/// enters the modeled ecosystem.
pub fn gasBoundaryExchangeG(
    soil_flux_g_per_h: []const f64,
    litter_flux_g_per_h: []const f64,
    first_soil_layer: usize,
    soil_layer_count: usize,
    litter_cell: usize,
    species: gas.Species,
) !f64 {
    return (try gasBoundaryExchangeComponentsG(
        soil_flux_g_per_h,
        litter_flux_g_per_h,
        first_soil_layer,
        soil_layer_count,
        litter_cell,
        species,
    )).total_exchange_g;
}

/// Projects HOUR1/OUTSH `CNH3S`: non-band aqueous NH3 mol N per cubic metre
/// of non-band water, converted to g N m-3. It is deliberately not read from
/// the seven-gas dissolved-ammonia inventory.
pub fn writeMineralAmmoniaNitrogenProfile(
    aqueous: []const AqueousState,
    first_soil_layer: usize,
    soil_layer_count: usize,
    nitrogen_molar_mass_g_per_mol: f64,
    output_g_n_per_m3: []f64,
) !void {
    if (first_soil_layer > aqueous.len or soil_layer_count > aqueous.len - first_soil_layer or output_g_n_per_m3.len != soil_layer_count) return error.MineralAmmoniaOutputDimensionMismatch;
    if (!std.math.isFinite(nitrogen_molar_mass_g_per_mol) or nitrogen_molar_mass_g_per_mol <= 0) return error.InvalidNitrogenMolarMass;
    for (output_g_n_per_m3, aqueous[first_soil_layer..][0..soil_layer_count]) |*output, layer| {
        if (!std.math.isFinite(layer.ammonia_non_band) or layer.ammonia_non_band < 0) return error.InvalidMineralAmmoniaOutputState;
        output.* = layer.ammonia_non_band * nitrogen_molar_mass_g_per_mol;
        if (!std.math.isFinite(output.*)) return error.NonFiniteMineralAmmoniaOutput;
    }
}

test "boundary exchange retains legacy positive-into-ecosystem sign over runtime layers" {
    var soil = [_]f64{0} ** (4 * gas.species_count);
    var litter = [_]f64{0} ** (2 * gas.species_count);
    soil[1 * gas.species_count + @intFromEnum(gas.Species.carbon_dioxide)] = 2;
    soil[2 * gas.species_count + @intFromEnum(gas.Species.carbon_dioxide)] = -0.5;
    litter[1 * gas.species_count + @intFromEnum(gas.Species.carbon_dioxide)] = 0.25;
    const components = try gasBoundaryExchangeComponentsG(
        &soil,
        &litter,
        1,
        2,
        1,
        .carbon_dioxide,
    );
    try std.testing.expectEqual(@as(f64, 1.5), components.soil_exchange_g);
    try std.testing.expectEqual(@as(f64, 0.25), components.litter_exchange_g);
    try std.testing.expectEqual(@as(f64, 1.75), components.total_exchange_g);
    try std.testing.expectEqual(@as(f64, 0), components.splitClosureResidualG());
    try std.testing.expectEqual(@as(f64, 1.75), try gasBoundaryExchangeG(&soil, &litter, 1, 2, 1, .carbon_dioxide));
}

test "CNH3S projection uses runtime nitrogen molar mass and arbitrary layers" {
    var aqueous = [_]AqueousState{std.mem.zeroes(AqueousState)} ** 4;
    aqueous[1].ammonia_non_band = 0.5;
    aqueous[2].ammonia_non_band = 2;
    var output: [2]f64 = undefined;
    try writeMineralAmmoniaNitrogenProfile(&aqueous, 1, 2, 14, &output);
    try std.testing.expectEqual([2]f64{ 7, 28 }, output);
}

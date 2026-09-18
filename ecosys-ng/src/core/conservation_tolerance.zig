const std = @import("std");

/// Optional user-specified physical closure floors, each in its own native
/// unit per square metre. Zeros request no user floor; the audit still applies
/// a dynamically derived floating-point representation floor and its
/// dimensionless relative criterion.
pub const AbsolutePerArea = struct {
    water_m: f64 = 0,
    heat_megajoules_m2: f64 = 0,
    oxygen_g_m2: f64 = 0,
    carbon_g_m2: f64 = 0,
    nitrogen_g_m2: f64 = 0,
    phosphorus_g_m2: f64 = 0,
    /// Historical runscript field name retained for input compatibility. It
    /// is applied independently to each conserved Al/Fe/Ca/Mg/Na/K/S/Cl/Si
    /// balance in mol m-2. The REDIST SSB/TION pseudo-ion diagnostic is not an
    /// acceptance quantity because association/dissociation changes it.
    ions_mol_m2: f64 = 0,
    hydrogen_g_m2: f64 = 0,
    sand_megagrams_m2: f64 = 0,
    silt_megagrams_m2: f64 = 0,
    clay_megagrams_m2: f64 = 0,
    /// REDIST ROCK is a source-defined additive layer owner, not a mass.
    rock_additive_m2: f64 = 0,
    exchange_capacity_mol_m2: f64 = 0,

    pub fn validate(self: AbsolutePerArea) !void {
        inline for (std.meta.fields(AbsolutePerArea)) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidMassBalanceAbsoluteTolerance;
        }
    }
};

test "per-domain physical conservation floors carry independent units" {
    const floors: AbsolutePerArea = .{
        .water_m = 1e-10,
        .heat_megajoules_m2 = 2e-8,
        .carbon_g_m2 = 3e-7,
    };
    try floors.validate();
    try std.testing.expect(floors.water_m != floors.heat_megajoules_m2);
    try std.testing.expectError(
        error.InvalidMassBalanceAbsoluteTolerance,
        (AbsolutePerArea{ .ions_mol_m2 = -1 }).validate(),
    );
}

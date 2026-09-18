//! `litter_chemistry` declarations: fixtures.
//!
//! Split out of `litter_chemistry.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const ledger = @import("litter_reaction_transformations.zig");
const activity_coefficients = @import("../soil/solute/activity_coefficients.zig");
const numerics = @import("../core/numerics.zig");
const group_struct_arithmetic = @import("litter_chemistry_struct_arithmetic.zig");
const group_types = @import("litter_chemistry_types.zig");

/// Supplies litter-specific reaction extents.  Keeping this callback free of
/// allocation lets the same solver drive CPU grid kernels and future GPU rate
/// evaluators without embedding storage policy in the science equations.
pub const Evaluator = struct {
    context: *const anyopaque,
    evaluate: *const fn (context: *const anyopaque, cell: group_types.Cell) anyerror!ledger.ReactionExtents,
    equilibrate_cation_exchange: ?*const fn (context: *const anyopaque, cell: group_types.Cell) anyerror!group_types.Cell = null,
    phosphate_mineral_equilibrium_residuals: ?*const fn (
        context: *const anyopaque,
        cell: group_types.Cell,
    ) anyerror!ledger.PhosphateMineralExtents = null,
    /// Optional source-order projection applied before the production hourly
    /// kinetic ledger. SOLUTE.F 4238--4265 fully equilibrates the starting
    /// H/OH pair before evaluating the remaining reactions; it is not part of
    /// the later shared active-set fraction.
    project_starting_water_equilibrium: ?*const fn (
        context: *const anyopaque,
        cell: group_types.Cell,
    ) anyerror!WaterEquilibriumProjection = null,
    /// Optional production terminal replay. Residual/probe evaluations never
    /// invoke it; `solveCell` calls it once immediately before state commit.
    project_water_equilibrium: ?*const fn (
        context: *const anyopaque,
        cell: group_types.Cell,
    ) anyerror!WaterEquilibriumProjection = null,
};

pub const WaterEquilibriumProjection = struct {
    cell: group_types.Cell,
    equal_reaction_extent_mol_per_m3: f64,
};

pub const TestContext = struct { rate_fraction: f64 };

pub fn testEvaluator(raw: *const anyopaque, cell: group_types.Cell) !ledger.ReactionExtents {
    const context: *const TestContext = @ptrCast(@alignCast(raw));
    var extents: ledger.ReactionExtents = undefined;
    group_struct_arithmetic.zeroValue(ledger.ReactionExtents, &extents);
    extents.ammonium_association_mol_per_m3 = context.rate_fraction * (cell.ammonia_mol_per_m3 - cell.ammonium_mol_per_m3);
    extents.external_hydrogen_mol_per_m3 =
        extents.ammonium_association_mol_per_m3;
    return extents;
}

pub fn failingCationExchange(
    _: *const anyopaque,
    _: group_types.Cell,
) !group_types.Cell {
    return error.SyntheticNestedExchangeFailure;
}

pub fn cationBoundPhosphateEvaluator(
    _: *const anyopaque,
    cell: group_types.Cell,
) !ledger.ReactionExtents {
    var extents = std.mem.zeroes(ledger.ReactionExtents);
    extents.phosphate_minerals.aluminum_phosphate_mol_per_m3 =
        0.2 * cell.aluminum_mol_per_m3;
    extents.phosphate_minerals.iron_phosphate_mol_per_m3 =
        0.2 * cell.iron_mol_per_m3;
    return extents;
}

pub fn supersaturatedAluminumAndIronPhosphate(
    _: *const anyopaque,
    _: group_types.Cell,
) !ledger.PhosphateMineralExtents {
    return .{
        .aluminum_phosphate_mol_per_m3 = 1,
        .iron_phosphate_mol_per_m3 = 1,
        .dicalcium_phosphate_mol_per_m3 = 0,
        .hydroxyapatite_mol_per_m3 = 0,
        .monocalcium_phosphate_mol_per_m3 = 0,
    };
}

/// Reproduces the Ottawa hour-1 non-convergence signature that blocked the
/// whole project (SOLUTE-PHOSPHATE-EQUIL). Every phosphate rate sits pinned at
/// a source kinetic ceiling, so the rates are locally constant in the state
/// and their directional derivative is identically zero. No equilibrium
/// iteration can reduce such a residual: the map has no fixed point because a
/// saturated kinetic rate is not an equilibrium condition.
///
/// The source's ISALTG=0 litter branch (`solute.f` 4009--4016, 4682--4719) sets
/// `TPD=TPDH*XNFH`, `TPZ=TPZH*XNFH` and `TPA=TRW=TRWH*XNFH`, and sits *outside*
/// `DO 1000 M=1,MRXN` (which closes at line 2712), so Fortran state_updates
/// exactly one bounded hourly increment and never iterates these rates to a
/// residual. Iterating them instead multiplies one hour of precipitation by the
/// iteration ceiling and then fails fast.
///
/// Which constant bounds which mineral, verified against the litter branch
/// rather than assumed (`solute.f:451` names the pools: `PCAPM`/`PCAPD`/`PCAPH`
/// are CaH2PO4/CaHPO4/apatite):
///
/// | mineral | litter-branch ceiling | source line |
/// | --- | --- | --- |
/// | AlPO4, FePO4, CaHPO4 | `TPD` from `TPDH=2.5E-03` | 4573, 4582, 4591 |
/// | monocalcium Ca(H2PO4)2 | `TPZ` from `TPZH=2.5E-02` | 4606, 4718 |
/// | hydroxyapatite Ca5(PO4)3OH | `TPA=TRW` from `TRWH=5.0E-05` | 4598, 4711 |
///
/// An earlier version of this comment attributed `TPZH=2.5E-02` to
/// hydroxyapatite. `TPZH` bounds MONOCALCIUM phosphate; apatite is bounded by
/// `TRWH`, the same constant the header at `:98--103` documents for silicate
/// weathering, which the source reuses here. The salt-ENABLED soil branch is
/// different again -- apatite there is bounded by `TPDA=TPDX=(TPDH/MRXN)*XNFH`
/// at `:2023` -- so a ceiling read off this litter branch must not be applied
/// to the soil field, and vice versa.
///
/// The magnitudes below are the raw hourly `*H` constants, not the per-substep
/// `*XNFH` values the source actually caps with (`XNFH=1/NFH`, `NFH=4`). That
/// is deliberate and harmless for what this fixture demonstrates: a constant
/// extent has an identically zero derivative at any magnitude. Do not read
/// these numbers as the oracle's rate ceilings.
pub fn saturatedCeilingPhosphateEvaluator(
    _: *const anyopaque,
    _: group_types.Cell,
) !ledger.ReactionExtents {
    var extents = std.mem.zeroes(ledger.ReactionExtents);
    // Fortran TPDH=2.5E-03 ceiling, three minerals precipitating at the cap.
    extents.phosphate_minerals.aluminum_phosphate_mol_per_m3 = 2.5e-3;
    extents.phosphate_minerals.iron_phosphate_mol_per_m3 = 2.5e-3;
    extents.phosphate_minerals.dicalcium_phosphate_mol_per_m3 = 2.5e-3;
    // Fortran TRWH=5.0E-05, the `TPA=TRW` apatite ceiling of the litter branch
    // (`solute.f:4598`). NOT TPZH, which bounds monocalcium phosphate.
    extents.phosphate_minerals.hydroxyapatite_mol_per_m3 = 5.0e-5;
    return extents;
}

pub fn divergentEvaluator(
    _: *const anyopaque,
    _: group_types.Cell,
) !ledger.ReactionExtents {
    var extents = std.mem.zeroes(ledger.ReactionExtents);
    // Constant nonzero ammonium association: the residual never vanishes and
    // the state always changes, so neither the converged nor the stagnated
    // exit can be taken.
    extents.ammonium_association_mol_per_m3 = 0.1;
    return extents;
}

// **A8a DISPOSITION: NOT A BINDING CANDIDATE. This file is test
// infrastructure, not a translated module, and it must never be bound.**
//
// Why the census lists it. `tools/census_reach.py` enumerates `.zig` files
// under `src` and reports any file with no production caller as unbound. This
// file has no production caller and must not acquire one. It is one of the
// sixteen per-subsystem test indexes in `src/index/`, all sixteen of which
// appear in the unbound list for the same reason and none of which is a
// translation of any Fortran routine. There is no `.f` source to cite here
// because there is no science in this file.
//
// What it actually does, and why the mechanism is easy to misread. It holds
// 172 `_ = <module>;` references. It is imported at `module_index.zig:1376`,
// and the decisive detail is that the import sits *inside* the `test {}` block
// opened at `module_index.zig:1360` and closed at `:1382`, alongside the other
// fifteen indexes at `:1366--1381`. That placement is load-bearing in a way
// that is easy to get wrong: `@import` alone does not pull a module's tests
// into analysis, only an explicit `_ = module;` reference does. So this file
// is the thing that makes 172 modules' tests actually compile and run under
// `zig build test`, and it does its job precisely by having no production
// caller.
//
// Consequence for anyone draining the unbound list. Binding this file, or
// adding a `pub const` for it outside the test block, would not raise
// coverage; it would move test-only code into the production graph. Deleting
// it, or dropping a `_ =` line from it, silently removes modules from test
// analysis while every gate and build still passes, because nothing fails when
// a test simply stops being compiled. That is the most dangerous possible edit
// in this directory and it leaves no trace. Treat the `_ =` lines as append-
// only.
//
// Census false positive of the CENSUS-ORPHAN-FP-001 kind, already filed. The
// sixteen index files are a known and permanent residue in the unbound count:
// they can never be bound, so the count can never reach zero by binding alone,
// and any future report of remaining unbound modules should subtract them
// rather than treat them as outstanding work. The same reasoning applies to
// per-module test sidecars such as
// `soil/solute/concentration_initialization_test.zig`, which carries its own
// banner to that effect.
//
// A8a phase 2, src/index directory sweep. See
// docs/traceability/a8a_index_dispositions.md for the directory-level record.
//! Compiles the surface and pond redistribution modules so `zig build test` runs their tests.
//!
//! Referencing a module here is what pulls it into analysis. The
//! namespace itself still lives in `module_index.zig`; this file only
//! carries the references, grouped by directory so the list is
//! reviewable and a missing module is visible.

const ecosys = @import("../module_index.zig");

test {
    _ = ecosys.pond_layer_transition;
    _ = ecosys.redist_artificial_drainage_reset;
    _ = ecosys.redist_bulk_air_temperature_vapor;
    _ = ecosys.redist_call_initialization;
    _ = ecosys.redist_canopy_gas_closeout;
    _ = ecosys.redist_daily_litter_salt_inventory;
    _ = ecosys.redist_erosion_organic_matter_apply;
    _ = ecosys.redist_litter_dissolved_organic_update;
    _ = ecosys.redist_litter_ion_transport_senescence_apply;
    _ = ecosys.redist_mobile_water_table_adjustment;
    _ = ecosys.redist_natural_drainage_reset;
    _ = ecosys.redist_overland_flow_litter_salt_update;
    _ = ecosys.redist_snow_redistribution_salt_update;
    _ = ecosys.redist_snow_redistribution_solute_update;
    _ = ecosys.redist_surface_gas_flux_accounting;
    _ = ecosys.redist_surface_litter_compatibility;
    _ = ecosys.redist_surface_litter_microbial_biomass_removal;
    _ = ecosys.redist_surface_litter_removal_closeout;
    _ = ecosys.redist_surface_litter_soluble_removal;
    _ = ecosys.redist_surface_litter_som_removal;
    _ = ecosys.redist_tillage_activity;
    _ = ecosys.redist_tillage_chemical_redistribution;
    _ = ecosys.redist_tillage_fixation_normalization;
    _ = ecosys.redist_tillage_gas_redistribution;
    _ = ecosys.redist_tillage_layer_accumulation;
    _ = ecosys.redist_tillage_macropore_scaling;
    _ = ecosys.redist_tillage_mineral_incorporation;
    _ = ecosys.redist_tillage_mixing_initialization;
    _ = ecosys.redist_tillage_nitrogen_band_reset;
    _ = ecosys.redist_tillage_organic_ledger_recalculation;
    _ = ecosys.redist_tillage_organic_redistribution;
    _ = ecosys.redist_tillage_phosphate_fertilizer_band_reset;
    _ = ecosys.redist_tillage_physical_redistribution;
    _ = ecosys.redist_tillage_runtime_adapter;
    _ = ecosys.redist_tillage_salt_incorporation;
    _ = ecosys.redist_tillage_soc_lability;
    _ = ecosys.redist_tillage_surface_biomass_transfer;
    _ = ecosys.redist_tillage_surface_chemical_transfer;
    _ = ecosys.redist_tillage_surface_organic_transfer;
}

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
// What it actually does, and why the mechanism is easy to misread. It holds 11
// `_ = <module>;` references. It is imported at `module_index.zig:1381`, and
// the decisive detail is that the import sits *inside* the `test {}` block
// opened at `module_index.zig:1360` and closed at `:1382`, alongside the other
// fifteen indexes at `:1366--1381`. That placement is load-bearing in a way
// that is easy to get wrong: `@import` alone does not pull a module's tests
// into analysis, only an explicit `_ = module;` reference does. So this file
// is the thing that makes 11 modules' tests actually compile and run under
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
//! Compiles the validation and diagnostics modules so `zig build test` runs their tests.
//!
//! Referencing a module here is what pulls it into analysis. The
//! namespace itself still lives in `module_index.zig`; this file only
//! carries the references, grouped by directory so the list is
//! reviewable and a missing module is visible.

const ecosys = @import("../module_index.zig");

test {
    _ = ecosys.conservation_survey;
    _ = ecosys.coupled_gas_failure_reporter;
    _ = ecosys.coupled_gas_failure_snapshot;
    _ = ecosys.ecosystem_energy_ledger;
    _ = ecosys.initial_balance_ledger;
    _ = ecosys.landscape_boundary_ledger;
    _ = ecosys.landscape_mass_balance_runtime;
    _ = ecosys.landscape_mass_inventory;
    _ = ecosys.mass_balance_audit;
    _ = ecosys.hourly_cell_conservation;
    _ = ecosys.accumulated_cell_conservation;
    _ = ecosys.layer_local_conservation;
    _ = ecosys.layer_mass_inventory;
    _ = ecosys.op21_checkpoint_compile_regression;
    _ = ecosys.op21_compile_regression;
    _ = ecosys.relayering_layer_snapshot;
    _ = ecosys.output_unit_convention;
    _ = ecosys.production_freezing_column_validation;
    _ = ecosys.constant_forcing_steady_state;
    _ = ecosys.henry_solubility_validation;
    _ = ecosys.saturation_vapor_validation;
    _ = ecosys.soil_water_retention_validation;
    _ = ecosys.stage_execution_census;
    _ = ecosys.stefan_freezing_validation;
    _ = ecosys.tillage_adapter_compile_regression;
    _ = ecosys.tillage_dispatch_compile_regression;
    _ = ecosys.vanilla_picard_regression_test;
}

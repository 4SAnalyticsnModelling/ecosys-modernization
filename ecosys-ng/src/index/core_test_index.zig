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
// What it actually does, and why the mechanism is easy to misread. It holds 7
// `_ = <module>;` references. It is imported at `module_index.zig:1369`, and
// the decisive detail is that the import sits *inside* the `test {}` block
// opened at `module_index.zig:1360` and closed at `:1382`, alongside the other
// fifteen indexes at `:1366--1381`. That placement is load-bearing in a way
// that is easy to get wrong: `@import` alone does not pull a module's tests
// into analysis, only an explicit `_ = module;` reference does. So this file
// is the thing that makes 7 modules' tests actually compile and run under `zig
// build test`, and it does its job precisely by having no production caller.
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
//! Compiles the core numerics and configuration modules so `zig build test` runs their tests.
//!
//! Referencing a module here is what pulls it into analysis. The
//! namespace itself still lives in `module_index.zig`; this file only
//! carries the references, grouped by directory so the list is
//! reviewable and a missing module is visible.

const ecosys = @import("../module_index.zig");

test {
    _ = ecosys.compute;
    _ = ecosys.config;
    _ = ecosys.iteration_control;
    _ = ecosys.ice_units;
    _ = ecosys.numerics;
    _ = ecosys.options;
    _ = ecosys.simulation_timeline;
    _ = ecosys.execution_evidence;
}

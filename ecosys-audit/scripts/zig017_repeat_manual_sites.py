#!/usr/bin/env python3
"""Manual array-repeat sites the codemod cannot type-recover (zig017 fill migration).

`ecosys-audit/scripts/zig017_repeat_fill_migration.py` rewrites every repeat whose
element type is visible in the expression.  A handful of sites pass an anonymous
repeat into a function argument or a nested-array field, so the element type only
exists in the *callee* signature; the codemod refuses them and reports MANUAL.
This script performs exactly those rewrites, one literal per site, quoting the
signature that supplies the element type.  It is idempotent and fails loudly if a
pattern is missing or ambiguous, so it cannot silently miss or invent a site.

Every rewrite is value-preserving: `[_]T{v} * n` and `filled(n, T, v)` both build
an n-element array with every element equal to `v`.  No science changes.

Usage: uv run ecosys-audit/scripts/zig017_repeat_manual_sites.py [--dry-run]
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))

import zig017_repeat_fill_migration as codemod  # noqa: E402

SRC = REPO / "ecosys-ng" / "src"

# (relative file, expected occurrences, old literal, new literal, why manual)
SITES: list[tuple[str, int, str, str, str]] = [
    (
        "driver/fertilizer_production_fixture.zig",
        1,
        "&(.{@as(f64, 1)} * (cells * 3))",
        "&arr_compat.filled((cells * 3), f64, @as(f64, 1))",
        "row_spacing_m_by_cell_family: []const f64 slice literal",
    ),
    (
        "ecosys_ng.zig",
        1,
        "@memset(root_nutrient_traits, .{inactive_nutrient_trait} * 3);",
        "@memset(root_nutrient_traits, arr_compat.filled(3, ecosys.plant_traits.NutrientUptake, inactive_nutrient_trait));",
        "memset value is itself a [3]NutrientUptake array",
    ),
    (
        "plant/growth/shoot_growth_metabolism.zig",
        3,
        "coefficients(.{ 0.5, 0.2, 0.1, 0.1, 0.05, 0.05, 0 }, .{0.8} * partition_module.organ_count, .{0.04} * partition_module.organ_count, .{0.004} * partition_module.organ_count, parameters.minimum_leaf_nutrient_fraction)",
        "coefficients(.{ 0.5, 0.2, 0.1, 0.1, 0.05, 0.05, 0 }, arr_compat.filled(partition_module.organ_count, f64, 0.8), arr_compat.filled(partition_module.organ_count, f64, 0.04), arr_compat.filled(partition_module.organ_count, f64, 0.004), parameters.minimum_leaf_nutrient_fraction)",
        "coefficients args 2..4 are [organ_count]f64 (signature line 136-141)",
    ),
    (
        "soil/biogeochemistry/organic_substrate_decomposition.zig",
        1,
        ".{ .particulate = .{organic.ElementPool{}} * organic.structural_fraction_count, .dissolved = undefined }",
        ".{ .particulate = arr_compat.filled(organic.structural_fraction_count, organic.ElementPool, organic.ElementPool{}), .dissolved = undefined }",
        "StructuralProducts.particulate: [structural_fraction_count]organic.ElementPool",
    ),
    (
        "soil/organic/initialization.zig",
        1,
        "&(.{0.1} * (substrate_count * kinetic_fraction_count))",
        "&arr_compat.filled((substrate_count * kinetic_fraction_count), f64, 0.1)",
        "microbial_budget_fraction: []const f64",
    ),
    (
        "soil/organic/initialization.zig",
        1,
        "&(.{0.1} * (substrate_count * microbial_population_count * kinetic_fraction_count))",
        "&arr_compat.filled((substrate_count * microbial_population_count * kinetic_fraction_count), f64, 0.1)",
        "microbial_nitrogen_to_carbon: []const f64",
    ),
    (
        "soil/organic/initialization.zig",
        1,
        "&(.{0.01} * (substrate_count * microbial_population_count * kinetic_fraction_count))",
        "&arr_compat.filled((substrate_count * microbial_population_count * kinetic_fraction_count), f64, 0.01)",
        "microbial_phosphorus_to_carbon: []const f64",
    ),
    (
        "surface/autotrophic_complex_step.zig",
        1,
        "result.surface_mineral_capacity = .{.{0} * competition_history.surface_pool_count} * active_population_count;",
        "result.surface_mineral_capacity = arr_compat.filled(active_population_count, [competition_history.surface_pool_count]f64, arr_compat.filled(competition_history.surface_pool_count, f64, 0));",
        "nested field [active][pool]f64 (decl line 431)",
    ),
    (
        "surface/autotrophic_complex_step.zig",
        1,
        "result.topsoil_residual_capacity = .{.{0} * competition_history.surface_pool_count} * active_population_count;",
        "result.topsoil_residual_capacity = arr_compat.filled(active_population_count, [competition_history.surface_pool_count]f64, arr_compat.filled(competition_history.surface_pool_count, f64, 0));",
        "nested field [active][pool]f64 (decl line 432)",
    ),
]


def main(argv: list[str]) -> int:
    dry = "--dry-run" in argv
    changed: dict[Path, str] = {}
    problems: list[str] = []
    for rel, count, old, new, why in SITES:
        path = SRC / rel
        text = changed.get(path, path.read_text(encoding="utf-8"))
        found = text.count(old)
        if found != count:
            problems.append(f"{rel}: expected {count} occurrence(s), found {found}: {old[:70]}")
            continue
        text = text.replace(old, new)
        changed[path] = text
    if problems:
        for p in problems:
            print(f"MANUAL-SITE MISMATCH {p}", file=sys.stderr)
        return 2
    for path, text in sorted(changed.items()):
        text = codemod.add_import(text, path)
        if dry:
            print(f"would rewrite {path.relative_to(REPO)}")
            continue
        path.write_text(text, encoding="utf-8")
        print(f"rewrote {path.relative_to(REPO)} ({len(changed)} files total)")
    print(f"manual sites applied  : {len(SITES)} across {len(changed)} files{'  (dry)' if dry else ''}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

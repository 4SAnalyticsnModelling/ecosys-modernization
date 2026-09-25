# Hourly state dump, format v1 (plan P2.1-P2.3)

Both writers (the instrumented legacy copy in `evidence/oracle-src/` and the Zig build option)
emit this format, so `divcheck.py` compares them without adapters.

## Record
One record per line, ASCII, whitespace-separated, exactly 4 fields:

```
<key> <VAR> <index> <value>
init THETA 3 3.21000000000000019e-01
1.1.1.17.9 ZNH4S 5 1.23456789012345678e-02
```

| Field | Meaning |
|---|---|
| key | `init` (after initialization, before the first time advance) or `S.R.Y.D.H`: scene, repeat, year, day-of-year, hour; integers, no padding |
| VAR | the legacy Fortran variable name, uppercase (the Zig writer maps its field to this name) |
| index | comma-joined integers in LEGACY index space, in legacy declaration order (e.g. `L,NY,NX`). Lower bounds follow the legacy declaration (often 0). Scalars use `-` |
| value | f64, 17 significant digits (`ES25.17E3` in Fortran, `{e:.17}` in Zig). `D` exponents are accepted |

- Keys are written in nondecreasing chronological order; `init` first.
- One file per simulated year is recommended: `dump-<S>-<R>-<Y>.txt`, plus `dump-init.txt`.
- No record may repeat within a key.
- Precision: the legacy build is `-r8 -i4` with no IMPLICIT statements, so every real is f64. Never
  dump through a REAL*4 temporary.

## Variable registry
`state-dump-v1.json` lists each dumped variable: units, dimension names, lower bounds, process
group (used for divcheck clusters) and the Zig field it maps to. The curated set (plan P2.1) is
per-layer water/ice/heat, C/N/P pools, NH4/NO3/PO4 including band zones, Ca/Na/K/Mg and other
active salts, gases, root/plant pools, snow and surface. **The registry is empty until P2.1 fills it
from `f77query.py common <BLK> --users` evidence. Do not guess a mapping.**

## Non-perturbation requirement
The instrumented legacy build must produce standard outputs byte-identical to the uninstrumented
reference (P2.1). The Zig dump is a build option that is off in production and performance builds.

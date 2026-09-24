# issue-100 -- hour 3,276 nitrogen residual decomposed by stage interval (2026-09-24)

Task `20260924-010007-ad41eae1`. No source change and no new run. Input: `audit/runs/issue-100-n100f-run/stderr.log` (run-028), SHA256 `b547c3a872c351367eb80223f5cb28787dde2127fb40562cfeb48a88b6d8d6c6`. Its `hourly post-NITRO conservation trace` line (line 12017) holds the six storage-side N pools that the cell census sums, at seven points: `after_nitro, after_post_watsub, after_uptake, after_chemistry, after_transport, after_interface_heat, after_surface_gas`.

## Method

The printed decimals were parsed with Python `fractions.Fraction` (exact, with no float re-rounding) and combined with the cell-0 failure row (line 12015) and the two booked inputs from run-028 (fertilizer 1.65 and a second producer of 6.63635480278274e-3). The script is reproduced below so it can be rerun independently.

## Result

The six-pool sum at `after_surface_gas` minus the row's `after` is -4.1e-13, so this trace is the same census the failing row uses.

| Interval | Storage delta (g N) | Booked (g N) | Unbooked (g N) | Pools moving |
|---|---|---|---|---|
| hour start -> `after_nitro` | +1.573004887 | 1.65 (banded NH4 fertilizer) | **-0.0769951125131** | not resolved (no earlier trace point) |
| `after_nitro` -> `after_post_watsub` | 0 | 0 | 0 | none |
| `after_post_watsub` -> `after_uptake` | +0.009331124309 | 0 | **+0.009331124309** | NH4 +0.01027070702866, NO3 -0.0009395827194256; plant N unchanged at 0.0528 |
| `after_uptake` -> `after_chemistry` | -1.550395914e-6 | 0 | -1.55e-6 | NO3 |
| `after_chemistry` -> `after_transport` | +0.006636354804 | 6.63635480278274e-3 | ~0 | N2 +0.006636548198, NH4 -1.93e-7 |
| later intervals | ~-8e-13 | 0 | ~0 | none |

The unbooked pre-NITRO and post-NITRO components are -0.0769951125131 and +0.00932957391328. They sum to -0.0676655385998 against the reported residual of -0.0676655385994, so the decomposition is complete.

## Fertilizer identity

`ecosys-ng-prod-examples/.../management/soil/fertilizer/f25fr98` row `17051998` (day 137 = hour 3,276) has 1.65 in the fifth amount column. The field order is `fertilizer_schedule.zig:74-84`, and the fifth amount is `banded_ammonium`. The row also has 5.0 banded monocalcium phosphate, depth 0.05 m, width 0.76 m, band flag 1. The application is therefore a **single banded-NH4 species**. The pre-NITRO shortfall is 4.6664% of it, so it cannot be "one species' whole share of a mixed application". The hour-3,252 application (row `16051998`) is 13.8 broadcast urea.

## Conclusions (bounded)

1. The residual is the sum of **two opposite unbooked steps in different stages**, not one leak. The dominant step is -0.0770 g N somewhere between the hour-start snapshot and the end of NITRO, which is the interval containing the banded-NH4 deposit. A +0.00933 g N gain appears in the `after_post_watsub -> after_uptake` interval. That interval is a mineral-N change with no plant-N change in a pre-emergence run; root uptake is recorded as never executing.
2. The per-invocation ledger is exact (run-028), so both steps are storage-side: state or census, not accounting.
3. **Hypothesis, not established:** part of the banded NH4 is placed or converted into a band nitrogen species that the census's `ammonium_nitrogen_g` does not read (for example band aqueous NH3 or a band-only pool), and part of it re-enters a read pool in the uptake-interval stage. This predicts that a trace point placed immediately after the fertilizer publish shows a sum below `before + 1.65`.

## Next falsifiable step

Add TEMP_DIAGNOSTIC trace points at the hour start and immediately after the fertilizer publish (before NITRO). In the same run, print soil-layer-2 band/non-band NH4, NH3 (aqueous and gas) and urea separately at those points and at `after_uptake`. Do one ReleaseSafe run on the prod deck.

## Reproduction script

```python
import re
from fractions import Fraction as F
L = open('audit/runs/issue-100-n100f-run/stderr.log', encoding='utf-8').read().splitlines()
tr = [l for l in L if 'hourly post-NITRO conservation trace' in l][-1]
ks = ('residue_nitrogen_g','organic_nitrogen_g','dinitrogen_nitrogen_g','ammonium_nitrogen_g','nitrate_nitrogen_g','plant_nitrogen_g')
P = {k: [F(v.strip()) for v in re.search(k + r'=\{([^}]*)\}', tr).group(1).split(',')] for k in ks}
row = [l for l in L if 'hourly cell conservation failure: cell=0 quantity=nitrogen' in l][-1]
g = lambda k: F(re.search(k + r'=([-0-9.e+]+)', row).group(1))
tot = [sum(P[k][i] for k in ks) for i in range(7)]
pre = (tot[0] - g('before')) - F('1.65')
post = (tot[-1] - tot[0]) - F('6.63635480278274e-3') + g('external_outputs')
print(float(pre), float(post), float(pre + post), float(g('residual')))
```

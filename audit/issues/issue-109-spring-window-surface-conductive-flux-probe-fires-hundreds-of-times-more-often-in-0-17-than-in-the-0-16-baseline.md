<!-- workflow-policy: historical; reviewer-gates=retired -->
> **Current workflow:** All reviewer-decision, reviewer sign-off and human-approval
> requirements in this historical dossier are retired. The accountable leader resolves
> scientific questions from evidence and performs verification; no other actor grants permission.
> Supporting sub-agents are optional. Original observations and unresolved scientific
> evidence obligations below remain intact. Authority: [current protocol](../../.agent/protocol.md).

# Issue 109 -- 1998 d113+ (hour 2,712+): the surface conductive flux probe fires ~30x more often in the 2026-10-15 0.17 runs than in the 2026-09-24 0.16 baseline, and optimisation level is NOT the cause

Status: **OPEN — opened 2026-10-15 (cycle 00002); one of its three confounders is now killed by measurement, the deck
ceiling is being measured, the host/source axis is still open.**
Diagnostic-threshold evidence only: the check at `ecosys-ng/src/surface/temperature_solver.zig:778-798` is a
`std.log.err` probe with no clamp, no return and no tolerance — it cannot alter a number, and it exists precisely
because an earlier threshold on the same quantity was vacuous (comment at `:772-777`). Hit *counts* are therefore a
free behavioural fingerprint of the surface energy solution trajectory, not a failure by themselves.

## Corrected counts (measured 2026-10-15; these replace the first, wrong numbers in this issue)

All counts are `grep -c` over the complete `stderr.log`, attributed to a simulation day by the preceding
`info: daily conservation accepted: day=N year=YYYY hour=24` marker (that marker's `hour` field is the *day length*,
not a cumulative hour — the first version of this issue mis-read it, and also took totals from `summary.json`
`diagnostics`, which is a capped tally, not a count).

| log | build | reached | probe hits total | hits by d130 (h3,120) | first day |
|---|---|---|---|---|---|
| `audit/runs/issue-108-fix-run/stderr.log` | Zig 0.16.0, **ReleaseSafe**, Windows x86_64, deck f6=200 (`9ec1bf4e`) | d137 / h3,288 (fails 3,289) | **16** | **1** | d120 |
| `audit/runs/ottawa/zig017-releasesafe-run-20261015-2/stderr.log` | Zig 0.17.0, **ReleaseSafe**, macOS arm64, deck f6=100 (`ecf5e61a`) | d139 / h3,338 (wall-clock stop) | **1,313** | **524** | d113 |
| `audit/runs/ottawa/zig017-frontier-20261015-1/stderr.log` | Zig 0.17.0, **ReleaseFast**, macOS arm64, deck f6=100 (`ecf5e61a`) | d142 / h3,419 (wall-clock stop) | **9,734** | **524** | d113 |

So at the matched window the ratio is **524 : 1** (0.17 : 0.16) and, over the whole 0.17 run, 9,734 : 16. The probe
fires in *bursts* on particular spring/early-summer days* — not as a monotone drift: 0.17 hits by day,
`d113:1  d118:1  d119:87  d121:57  d124:42  d125:23  d130:313  …  d142:1,085`, with 16 hit-days out of 42 elapsed
days; the baseline's 16 hits land on only 2 days (d120, d135).

## The earlier and larger marker, found while checking confounder 1

The same three logs contain a second behavioural fingerprint that diverges **56 days earlier and ~600x harder**:
the fallback warning `aqueous extensive transport accepted best conservative state`
(`ecosys-ng/src/soil/gas/aqueous_extensive_transport.zig:455`) —

| log | hits | days hit | first day | last day | reasons |
|---|---|---|---|---|---|
| 0.16 baseline (f6=200, Windows, ReleaseSafe) | **2** | 1 | d85 | d85 | anderson-rejected |
| 0.17 ReleaseSafe (f6=100, macOS) | **1,237** | 18 | **d57** | d121 | iteration-limit 629, unrepresentable-update 401, anderson-rejected 207 |
| 0.17 ReleaseFast (f6=100, macOS) | **1,237** | 18 | **d57** | d121 | iteration-limit 629, unrepresentable-update 401, anderson-rejected 207 |

On d59-74 the count is 96/day = **every substep of every hour** of those days, with
`best_scaled_residual` reported in the 1e2-1e4 range. So for ~18 days the macropore aqueous extensive transport solve
never converges and every substep is published from the best-conservative fallback, while the daily audit still
accepts the day. Two facts make this the better lead than the spring probe:

1. **ReleaseSafe and ReleaseFast are identical here too** — same 1,237 hits, same 18 days, same reason mix, so this is
   also not an optimisation-level artefact.
2. **The emitting file is unchanged across the boundary being compared**: `git log -- ecosys-ng/src/soil/gas/aqueous_extensive_transport.zig`
   ends at `c84b60a` (2026-09-19), i.e. before the 2026-09-24 baseline, and the Zig 0.17 commit `026c309` did not touch
   the file at all. The wording (including `reason=iteration-limit` / `unrepresentable-update`) dates to the initial
   import `514dd68` (2026-09-18), so the baseline's build had the same strings and printed them twice.
   The cause is therefore upstream of this file — candidates within the 497 commits between 2026-09-24 and HEAD include
   `470810a` (2026-09-29, "stop the top-layer solids drain; **legacy-explicit gas pressure**") and `5ef5c26`
   (2026-09-30, denitrifier share fix), plus DEV-007's decoupling of the SOLUTE/STARTE ceilings from the deck f6
   (2026-09-26), which changed *which* ceiling governs this very solver.

## Confounder 1 — optimisation level: **KILLED** (measured, cycle 00002)

Same 0.17 source, same deck bytes (`ecf5e61a…`), same host, two build modes, independent processes:

- `audit/runs/ottawa/zig017-cross-mode-releasesafe-extended-vs-releasefast-20261015-1/zigdiff.json`:
  ReleaseSafe (to h3,338) vs ReleaseFast (to h3,419) → **status IDENTICAL**, 17 output streams,
  **382,178 common cells compared, 0 differing**, 0 rows only in the ReleaseSafe side, `max_abs = max_rel = 0.0`.
- The probe counts are then not merely similar but **equal day by day** through d130: both log
  `1, 1, 87, 57, 42, 23, 313` on d113/118/119/121/124/125/130 and 524 hits cumulatively.
- Corroboration from the shorter pairs: ReleaseSafe-2,400 h vs frontier = IDENTICAL (277,169 cells, 0 differing),
  rebuilt ReleaseFast vs frontier = IDENTICAL (332,920 cells, 0 differing). Debug is *not* digit-comparable to either
  (35,930 cells, 25,324 = 70.5% differing, first difference 1998 d001 h23 `root_length_density_layer_3` at 8.88e-16,
  worst 8.56e-8 abs / 3.15e-8 rel) — so mode matters only below the ulp-vs-Release boundary, and ReleaseSafe and
  ReleaseFast are the same trajectory on this host.

**Consequence: the divergence from the 0.16 baseline is not caused by `-O3`.** Any explanation must live on the deck
axis, the host/libm axis, or in the ~3 weeks of source changes between the two runs.

## Confounder 2 — deck iteration ceiling f6: **measuring now (cycle 00002)**

`git log` on the deck control file pins this confound exactly: `9253d3b` (2026-09-19, "raise SOLUTE iteration ceiling
100->200 … to clear hour-2589 frontier") wrote blob `9ec1bf4e7175910cfda2b9cdfa2a2cc4b104464f`
(`runtime,4,1,1e-8,1e-11,200,0.5`); `8a4a565` (2026-09-28, DEV-004 REJECT-REVERT) restored
`ecf5e61ab453288b1763f81f841729bee34e8426` (`…,100,0.5`), which is the hash-guarded HEAD deck. The 2026-09-24 baseline
sits between those commits, so **the baseline ran f6=200 and every 0.17 run above ran f6=100** — and note that
`9253d3b` raised the ceiling precisely because the model could not clear hour 2,589 at f6=100, i.e. this knob is known
to act in the same hour range where the probe now starts (hour 2,712).
Diagnostic run `audit/runs/ottawa/zig017-f6-200-diag-20261015-1` (this cycle): the *same* ReleaseFast binary as the
frontier, staged by `stage_ottawa_deck.py --blob 9ec1bf4e…` — the baseline's own control blob, so nothing is
hand-edited — hour 0, ReleaseFast, 2,400 s. **Not a qualification run** (it fails the strict stager's `ecf5e61a` guard
by design) and it cannot promote the frontier. Readout: probe hits per day on d113-130 against the table above.

## Confounder 3 — host libm / ISA + 3 weeks of source drift: **OPEN**

macOS arm64 (Apple clang libm, via Zig's own compiler-rt) vs Windows x86_64 (MinGW), plus every source commit between
2026-09-24 and HEAD. Not exonerated by anything measured here: a same-host 0.16 build is impossible (0.16 retired and
not installed, `build.zig.zon` pins `minimum_zig_version = "0.17.0"`), and the repository holds no 0.16 ReleaseFast
log and no legacy output stream for these hours (cycle 00002 §1 item 3), so no digit-level cross-boundary comparison
exists. Cheapest discriminating evidence left: matched-state kernel oracles from the gfortran legacy build
(`ecosys-source-navigation`), and a `git log -p` read of the surface-energy path over 2026-09-24..HEAD.

## Related but not this issue

`root salt implicit solve failed (RootSaltSolverDidNotConverge); used legacy explicit UPTAKE scheme over 100 substeps`
(`ecosys-ng/src/plant/root/plant_root_salt_exchange.zig:316`) fires 32 times on d141-142 (hours 3,384 / 3,408) — beyond
the baseline's reach, so nothing in the 0.16 log contradicts it. The "100 substeps" is the deck's `runtime` f6, and the
known 0.16-era occurrence of the same non-convergence was hour 3,562 (`d38218a`, adversarial r00008, 2026-09-29),
i.e. ~180 h later than now — one candidate reason being this same f6 difference.

## Confounder 2 — deck `f6` iteration ceiling: **KILLED (2026-10-15, experiment + algebra)**

Staged the baseline-era control blob `9ec1bf4e` (`runtime,4,1,1e-8,1e-11,200,0.5`, i.e. f6=200) under the same
ReleaseFast binary `a9e1ec25…` (`audit/runs/ottawa/zig017-f6-200-diag-20261015-1`, 2,400 s wall, reached d141):

| | baseline 0.16 Win (f6=200) | 0.17 macOS f6=100 | 0.17 macOS f6=200 |
|---|---|---|---|
| aqueous fallback | 2 (d85) | 1,237 (d57-d121) | **1,237 (d57-d121), identical reason mix and identical values** |
| first aqueous reason | anderson-rejected @ iter 28/30 | iteration-limit @ iter 100 | **iteration-limit @ iter 100** |
| probe first day | 120 | 113 | **113** |
| probe per-day | 1 / 15 | — | **equal to f6=100 through d140** (d139 2591 = 2591, d140 2053 = 2053) |
| outputs vs the f6=100 run | n/a | n/a | **IDENTICAL: 17/17 streams, 388,086 cells, 0 differing** |

Mechanism (`core/iteration_control.zig:96,119-141`): every ceiling the deck can move is
`@min(hard_max_iterations, X)` with `X <= 100`, and for this deck `NPH=4`, `NPG=1`, so `gas = min(hard, max(100,4)) = 100`
and `water_heat_solute = min(hard, max(100,4)) = 100` whether `hard` is 100 or 200; the solute ceilings are decoupled by
DEV-007. The deck's `f6` field therefore changes nothing at all for this deck once it is >= 100, which the bit-identical
outputs confirm. **What is left is the real question**: the same 100-iteration ceiling that the baseline also had, but
the solve now needs >100 iterations where the baseline converged in 28-30. Suspects are upstream state feeding
`aqueous_extensive_transport.zig` (file itself unchanged since `c84b60a`, 2026-09-19) or a genuinely different
trajectory — including the irreducible confounder that every `aq=2` log in this repository was produced on
`D:\ecosys-modernization` (Windows x86_64, Zig 0.16) and every `aq=1,237` log on macOS arm64 (Zig 0.17), with 735
commits between: no ancestor of `026c309` can be built on this host without installing Zig 0.16, so host-vs-code is not
separable by bisection here. Note the sensitivity this host already shows: Debug vs ReleaseFast (same ISA, same source)
differ in 70.5% of cells with `max_rel 3.15e-8` by day 11 — a 1-ulp cross-ISA difference amplifies into a different
solver schedule long before day 57, so **diagnostic counts across a toolchain/ISA change are not a parity oracle**;
authority is the legacy Fortran trajectory plus the closed daily ledgers, both of which pass.

## Next

0. **Start the localisation at d57 (hour 1,368), not at d113**: replay a matched state to hour ~1,340 and step to the
   first fallback substep, dumping the iteration reason, `best_scaled_residual` and the macropore state; compare against
   the legacy gas/aqueous exchange in `f77src/` via `f77query.py`. The 2-vs-1,237 gap is the signal; the spring probe is
   downstream of it.
1. Read `audit/runs/ottawa/zig017-f6-200-diag-20261015-1`: does f6=200 move the onset day and the per-day counts toward
   the baseline (first hit d120, 16 hits by d137)? Yes → the deck ceiling is the dominant confound and every
   0.16-vs-0.17 behavioural comparison must be re-run at a matched ceiling before it means anything.
   No → the deck is exonerated too, and only the host/source axis remains.
2. Localise with the `ecosys-divergence-diagnosis` order of work: state at hour 2,700 from a checkpoint, step to the
   first hour where the candidate fires and the baseline does not, per-substep trace of
   `conductive_heat_flux_megajoules_per_m2`, the conductance arms and `layer_thickness_m`; read the legacy surface
   energy conductance in `f77src/` (`f77query.py`, never a bulk `.f` read) before any code is touched.
3. Check the physics of the probe hits themselves: `flux_megajoules_per_m2 = -1.98` against the 5 MJ m-2 h-1 probe
   threshold, with `layer_thickness_m = 1.0015e-2` and `timestep_hours = 1.5625e-2` (1/64 h substep) — i.e. decide
   whether a ~2 MJ m-2 h-1 conductive flux at that substep is a defect at all, or a legitimately stiff spring morning
   that the 0.16 trajectory simply did not visit.

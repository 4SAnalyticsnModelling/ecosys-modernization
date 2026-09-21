# Issue 084 -- a usable gfortran oracle output set already exists on this host, and its "externally terminated" day-286 stop is actually `issue-023`

Status: **OPEN (informational/unblocking), filed 2026-09-21 by the adversarial Claude/Pi session.** Two findings: (a) a provenance-documented legacy oracle output set covering **hours 1-6,875** already exists on this host, which unblocks release criterion 3 for the whole range ecosys-ng can currently reach without the ~2h40m rebuild; (b) that artifact's own `PROVENANCE.md` misclassifies its stopping point, and the correct explanation is this project's already-diagnosed `issue-023`.

## (a) The artifact, and why it is usable here

Location (**not durable** -- a sibling agent's temp tree, not in the repo):

```
C:\Users\...\msys2\2025-02-21\tmp\claude\agentJ-base\validation\legacy_ottawa_gfortran_16_1\
  PROVENANCE.md
  source\        (the 40-file SRCS set it was built from, plus headers)
  ottawa_run\    (ecosys.x + 94 output/deck files, ~110 MB with the binary)
```

Copied to this session's scratchpad as `oracle-ottawa/` (94 files, 32.2 MB, `ecosys.x` excluded). **Integrity confirmed, not assumed**: `01998f25ch1` hashes to `F19A114C3314500068A8221EAB098D2D45C881154F822D025539DD0FD8B37DE5`, exactly the fingerprint its own `PROVENANCE.md` records.

**It is a valid oracle for THIS checkout.** Verified by hashing its `source/*.f` against `f77src/`:

- **34 of 40** files byte-identical.
- **5** (`BLOCKDATA001.f`, `exec.f`, `outpd.f`, `splitc.f`, `woutq.f`) hash differently but have **zero differing lines** -- line-ending/trailing-whitespace only.
- **1** (`soil.f`) differs by exactly **one line**: `      EXTERNAL SPLIT`. That is the documented gfortran compatibility declaration (GNU 16 treats the legacy external `SPLIT` as its Fortran 2023 intrinsic), already recorded in `CLAUDE.md` and `run-002`. No equation, branch, loop, COMMON or DATA change.

Toolchain and recipe match `run-002`'s independently-derived build exactly (gfortran 16.1.0; `-O2 -std=legacy -cpp -ffixed-form -ffixed-line-length-72 -fdefault-real-8 -fdefault-double-8 -falign-commons -fautomatic -fmax-stack-var-size=0 -fprotect-parens -fno-associative-math -fno-reciprocal-math -ffp-contract=off -fno-frontend-optimize -fallow-argument-mismatch`), including the same two input-deck contamination strips (the `van_genuchten_inflection_pressure_head_m` record from `f25sol98` and the trailing `weather_phase` record from each yearly option file). Two sessions arriving at the same recipe independently is worth something.

**Coverage**: `ottawa_run/01998f25ch1` holds 6,876 lines = 1 header + **6,875 hourly rows**, final row DOY 286.458, 14 October 1998, hour 11. ecosys-ng's current frontier is hour 3,253 (`issue-078`). **The oracle therefore covers ecosys-ng's entire reachable horizon roughly twice over**, so the "no oracle output available in this checkout" constraint does not bind any comparison work that is presently possible.

Streams present, both hourly (`h1`) and daily (`d1`), for cell prefixes `0` and `1`: carbon `c`, energy `e`, nitrogen `n`, phosphorus `p`, water `w` (e.g. `01998f25ch1`, `11998f25wd1`), plus `Cf21998`/`Nf21998`/`Mf21998`/`Wf21998` aggregate files.

### Carried limitations -- do not drop these when quoting a comparison

From the artifact's own provenance, and they are the right caveats: the inputs are a **documented reconstruction**, not provenance-backed originals; GNU cannot establish bitwise equivalence to the historical Intel target the makefile specifies; the fixed-width outputs omit most coupled-gas solver state; and the six-scene run did not complete. Its own words: "partial derived comparison artifact; not a trusted historical baseline." Treat it as the best available reference for **hours 1-6,875 of scene 1**, not as a certified baseline, and never renormalize its raw fixed-width bytes to make a comparison pass.

## (b) The day-286 stop is `issue-023`, not external termination

The artifact's `PROVENANCE.md` states: "`log98f25` ends while executing day 286. No Fortran error, fatal message, STOP, or backtrace was recorded. All output files stopped changing together, so the run is classified as **externally terminated** rather than scientifically complete."

**That classification is almost certainly wrong, and this project already has the diagnosis.** Evidence assembled here:

1. `log98f25`'s last line is `NOW EXECUTING DAY   286   OF YEAR  1998` with nothing after it -- an abrupt stop mid-day, not a clean finish.
2. The absence of an error in that file is expected rather than informative: it captures redirected **stdout**, while a gfortran runtime I/O error is written to **stderr**. "No error recorded" in a stdout log is not evidence that no error occurred.
3. The preserved `source/grosub.f` carries the `issue-023` defect **unfixed**. At `:12766` the live statement is
   ```fortran
         WRITE(*,8821)'CASNC0',I,J,NFZ,NX,NY,NZ,NB
   ```
   -- label plus **7** integers -- while its commented sibling at `:12772` reads `WRITE(*,8821)'SOSNC0',IYRC,I,J,NFZ,NX,NY,NZ,NB` with **8**, `IYRC` included. Shared `FORMAT 8821` at `:12778` is `(A8,8I4,30E12.4)`, i.e. **8** integers expected. Byte-identical in `f77src/grosub.f` (same line numbers, same format).
4. `issue-023` established that ifort silently tolerated this while gfortran's strict runtime I/O checking aborts **the first time a harvest-day event fires** (`DHVSTC.GT.0.0`). Day 286 is 14 October -- harvest season for the Ottawa maize/soybean deck.
5. `run-002` hit this exact crash at "day 286/year 1" and fixed it with the one-line `IYRC` restoration, after which its own run completed all 30 simulated years to exit 0.

So the same source, same compiler, same deck, same day, and a documented deterministic abort at that point. **The artifact is not "externally terminated"; it hit `issue-023` and died.** This matters in two ways: it is independent third-party confirmation of `issue-023` from a run made 8 days before that issue was filed, and it means the artifact's horizon is a **hard ceiling** set by a known, already-fixed legacy defect -- not an arbitrary interruption that a simple rerun would extend.

Not corrected in place: that `PROVENANCE.md` lives outside this repository, in a sibling agent's tree. It is not ours to edit, so the correction is recorded here instead.

## Recommended actions

1. **Use it** for the output comparison over hours 1-3,253. This is the cheapest path to real evidence on release criterion 3 and needs no Fortran rebuild.
2. **Decide on durability.** It is 32 MB of ASCII (excluding the binary) sitting in a temp tree that any cleanup will remove, and it costs ~2h40m to regenerate. Committing 32 MB of generated output conflicts with the standing root-cleanliness rule, so this is a coordinator/user call, not one to make silently. Until then, treat its availability as incidental.
3. **If the horizon must extend past day 286**, apply `issue-023`'s one-line `IYRC` fix to a scratch copy and rerun, per `run-002`'s recipe. Do not attempt to extend the existing artifact.

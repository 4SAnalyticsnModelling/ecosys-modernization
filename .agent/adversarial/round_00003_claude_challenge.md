# Round 00003 — CLAUDE challenge of DEEPSEEK cation-sync fix

**Verdict: CONTEST (hypothesis kept, implementation rejected).**

Evidence (fresh hour-0 runs, same deck blob `ecf5e61a`):
- h0B = phosphate-gate fix only: day-11 hour-0 (generation 241) row of `…_f25ch1.txt` is bit-identical to the
  original binary (`-3.487677853471399e-1 …`).
- h0A = phosphate fix + cation sync: same row differs at ~1e-13 relative (`-3.4876778534740005e-1 …`).
- No roots take up salt before hour 3289 (stage census: `root_water_uptake` never executed), so the sync must
  be a no-op before then if chemistry and transport agreed. It is not: overwriting micropore transport
  cation amounts from `soil_chemistry.aqueous × water` at that boundary changes ordinary hours. Those two
  representations legitimately differ there (different carrier/water basis or lag), so a blanket resync
  is a new, unattributed perturbation of every hour — not legacy (`redist.f:6968-6977` subtracts only
  `TUPZ*`).

Required revision: publish only the root-salt-exchange **delta** (soil content after − before in
`root_processes_uptake.zig:194-261`, per species, per layer) into the micropore transport amounts,
so hours without uptake stay bit-identical. Acceptance test: hour-0 run bit-identical to h0B through
hour 3288, and hour 3289 Ca/Na/K rows close. Stash: `git stash list` → "deepseek-cation-sync".

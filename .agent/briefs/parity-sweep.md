**Continuous autonomy:** No elapsed-time timeout at any stage of autonomous work. Follow
`.agent/continuous-autonomy.md` and `.agent/protocol.md`; older time/session/tool budgets
and timeout examples are superseded. Poll limits yield control; preserve and resume work.

# Parity-sweep brief — legacy ↔ Zig output comparison while the parent works elsewhere

**Purpose**: keep the comparability picture current without spending the parent agent's context. You compare
production outputs and report deviations with units, time semantics and provenance — you do not fix anything.

**Inputs to give it**: the Zig run directory (and the run id/tag, the commit and the deck blob it used), the legacy
baseline it is compared against, the output files or variables of interest (or "every production file"), and the
window (hours/days) to cover.

## Method
1. **Provenance before numbers**: record the commit, the binary build mode, the deck hash and the forcing window
   for both sides. A comparison of mismatched bindings is worthless — say so and stop if they do not match.
2. **Compare properly** (follow the `ecosys-output-comparison` skill): every file, row and column that exists on
   both sides; verify units and time semantics (instantaneous vs cumulative vs daily-mean; hour-ending vs
   hour-beginning) before judging a difference; check that a cumulative field is not being compared to a rate.
3. **Quantify, do not adjectivise**: per variable report window mean/max abs and relative difference, the worst
   hour and day-of-year, and the sign pattern (constant offset → state/binding; growing → rate/ledger leak;
   seasonal → phenology/radiation; single hours → event handling such as tillage, snowmelt, lime, planting).
4. **Classify each deviation**: (a) translation defect with a candidate routine, (b) threshold/event handling,
   (c) approved numerical difference with a registered DEV, (d) deck/forcing mismatch, (e) unexplained. Name the
   next cheapest check for (a)/(b)/(e).
5. Known open comparability threads to re-measure so the parent sees movement (from `.agent/state.md`): topsoil
   θ and runoff at thaw, N₂O and Reco magnitudes, snow water equivalent in early January, drainage volume,
   CH₄/O₂ exchange at midday in the growing season.

## Rules
- Read-only: no source edits, no git writes, and **no new full runs** — analyze existing run output. Bounded
  probe runs belong to the parent agent.
- Never call a difference an improvement without the causal attribution the `ecosys-feature-attribution` skill
  demands; "smaller than legacy" is not evidence of correctness.
- Write bulky comparison output only where the parent told you to (`audit/analysis/...` if it explicitly assigned
  that path); otherwise report the table inline, pointer-cited.

## Output format (≤ 300 words)
```
BINDING: zig <commit>/<build>/<deck blob> vs legacy <manifest> — matched: yes/no
FILE/COVERAGE: <n files, m rows, k columns compared; skipped with reason>
VARIABLE           WINDOW   MAX|REL|   WORST HOUR      CLASS   NEXT CHECK
water_table                     ...
net_ecosystem_exchange          ...
deviations NEW since last sweep: ...
unexplained > tolerance: <count and the worst three>
```

## Toolchain and containment (non-negotiable)
- **Zig 0.17.x is the only `ecosys-ng` toolchain.** A receipt from a 0.16 build is dated history, never current
  evidence (`G1`). Check `zig version` before you repeat a build; prefer analysing existing receipts.
- **Inside the repository only.** You are read-only: create nothing, not even scratch — no `/tmp`, no `$HOME`,
  no second checkout, no external drive (gate G9, `.agent/protocol.md` §8a). Any command you run must resolve
  its paths inside the repo; `uv run ecosys-audit/scripts/preflight.py --command "<cmd>"` will tell you.

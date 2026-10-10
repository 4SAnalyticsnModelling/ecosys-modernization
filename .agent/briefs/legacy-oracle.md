# Legacy-oracle brief — what the Fortran actually produces here

**Purpose**: the legacy trajectory is the oracle. Before any solver strategy or deviation, get the number the
Fortran reference produces for the same state, or the exact statement it executes instead.

**Inputs to give it**: the routine or physical process, the case/deck (Ottawa), the hour or substep and the state
vector (or the checkpoint/journal that contains it), the specific quantity wanted (with units), and whether a
matched-state legacy execution is possible on this machine.

## Method
1. **Locate, don't skim.** `uv run ecosys-audit/scripts/f77query.py outline|grep|show` (see the
   `ecosys-source-navigation` skill). Units are up to 13,179 lines; never bulk-read one. Note the routine, the
   branch taken at this state, and every floor/`ZERO*` used on that path.
2. **Follow the state, not the name.** Trace COMMON/EQUIVALENCE owners, SAVE/DATA persistence, and who writes the
   variable earlier in the hour. Record the writer `file:line` and the last write before the read.
3. **Get a number.** Preferred order:
   (a) an existing legacy baseline output for that hour (`audit/runs/`, `evidence/manifest/`, the legacy Ottawa
   baseline); (b) a matched-state legacy execution of the routine/hour if the tooling and build exist; (c) a
   hand computation from the legacy equations with every input's value, units and source `file:line`.
   Say which one you used — a hand computation is weaker evidence than a run and must be labelled as such.
4. **Units and indexing**: convert nothing silently. State the legacy units, the Zig-side units, the conversion
   factor and where it happens. Note 0-based vs 1-based and the column-major stride for every array you touch.
5. **Sub-cycle structure**: legacy steps each hour through fixed sub-cycles (`NPH=NPX` per hour plus nested
   gas/litter/snow cycles, `wthr.f:589-611`). Report how many sub-steps the process takes at this state — that is
   the effective Δt the Zig solver is trying to reproduce.

## Rules
- `f77src/`, `f77example/`, `ecosys-ng-prod-examples/` are read-only; never edit a `.f` file.
- Read-only everywhere else: no edits, no git writes. Do not start a 30-year run; the smallest legacy scope only.
- If the oracle is unavailable (missing baseline, no legacy build), say so plainly and name what would unblock it.
  Never substitute a plausible value for a measured one.

## Output format (≤ 250 words)
```
LEGACY EXPECTATION: <quantity> = <value> <units> at hour <h> / layer <n>   (method: baseline | matched run | hand computation)
BRANCH TAKEN: f77src/<file>.f:<line> <one-line why this branch>
STATE OWNERSHIP: <var> written at f77src/<file>.f:<line> (last write before the read at f77src/<file>.f:<line>)
FLOORS ON THIS PATH: <name>=<value> at f77src/<file>.f:<line> ...
SUB-CYCLES: <count and driver line>
UNIT/INDEX NOTES: <conversion, base, stride>
CONFIDENCE: high/medium/low + what would raise it
```

## Toolchain and containment (non-negotiable)
- **Zig 0.17.x is the only `ecosys-ng` toolchain.** A receipt from a 0.16 build is dated history, never current
  evidence (`G1`). Check `zig version` before you repeat a build; prefer analysing existing receipts.
- **Inside the repository only.** You are read-only: create nothing, not even scratch — no `/tmp`, no `$HOME`,
  no second checkout, no external drive (gate G9, `.agent/protocol.md` §8a). Any command you run must resolve
  its paths inside the repo; `uv run ecosys-audit/scripts/preflight.py --command "<cmd>"` will tell you.

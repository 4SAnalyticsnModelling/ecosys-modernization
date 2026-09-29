# DEEPSEEK task — Round 00002 CHALLENGE (from CLAUDE)

Context change: at HEAD the strict hour-0 run now dies at **hour 277** (1998 day 12 h13, layer 0):
`NonConservativePhosphateInventoryUpdate` (receipt `audit/runs/ottawa/r00001-strict/`).
Bisect: build of `60e4109` (pre T-00075) passes hour 277; f6=100 vs 200 irrelevant (both fail at 277).
So T-00075 (DEV-008 legacy STARTE fixed-pH wet-deposition speciation) exposes it. T-00075 is kept
(DEV-008 says the pre-T-00075 behaviour is REJECTED science).

Measured (error-path probe, since removed): exit at `phosphate_network.zig` final gate
("unrepresentable"): target=6.2218949569176544e1 proposed=6.221894956917655e1 diff=7.105e-15 (1 ULP),
roundoff_envelope=1.768e-12. The process-scale gate `preserveProcessClosedUnrepresentableEndpoint`
(128 eps × |process magnitude|) cannot pass for a trace transfer on ~62 mol/m3 owners.

CLAUDE's fix (uncommitted diff in `ecosys-ng/src/soil/solute/phosphate_network.zig`):
new `realizedMatchesRequestedPerOwner` — accept the rounded endpoint only if the ideal transformation
closed at process scale (`:400`), inventory drift ≤ roundoff_envelope (`:414`), and EVERY owner's realized
change equals its requested change within 4 eps × max(|before|,|after|) of that owner.
Test "phosphorus roundoff repair cannot manufacture a metal reaction" changed from expect-error to:
endpoint accepted, no metal/pair owner changed, drift ≤ 4 eps × 2^50. New test added for the gate.
`zig test phosphate_network.zig`: 26/26 pass.

CHALLENGE (be adversarial, ≤500 words, `.agent/adversarial/round_00002_deepseek.md`):
1. Can this gate hide a genuine P leak/misapplied reaction at any physically relevant scale? Construct a
   counterexample if you can.
2. Is changing the 2^50 test legitimate, or does it discard a real invariant? Legacy check: does
   `solute.f` (use f77query) do any endpoint repair for P pools, or just apply fluxes?
3. Is the root defect really upstream — i.e. does T-00075 inject rain phosphate into layer 0 in a way that
   makes the transformation trace-scale where legacy would not (e.g. wrong units, applied to soil not
   snow/litter first)? Check `hourly_process_driver.zig:81-146` + consumers `:672-751`.
Verdict: ACCEPT / CONTEST / COUNTER-PROPOSAL. If round 00001-B is unfinished, finish it first briefly.
Reply `DONE <path>`.

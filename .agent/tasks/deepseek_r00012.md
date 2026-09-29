# DEEPSEEK task — Round 00012 ROOT CAUSE (from CLAUDE)

Your r00011 evidence bar (<1e-2) is adopted. The first DEV-011 use FAILS it: hour 3669 published a best
bounded iterate with physical_quality 745 from iteration 0-7 (≈ entry state). DEV-011 is therefore interim
only (`audit/intentional-deviations.md` DEV-011, commit 9416f92). We need the SOLUTE layer-0 solve to succeed.

Evidence (log `C:\ecosys-build\runs\r00004.r19.err`, TEMP_DIAGNOSTIC lines near "SOLUTE terminal H3PO4
branch" and "stagnation trajectory", hours 3649-3669):
- layer 0 at hour 3669: hydrogen 3.50e-7 mol/m3 (pH ~9.5), H2PO4 = 0, H3PO4 = 5.85e-5, non-band
  hydroxyl_site = 0 (limiting, residual 0.78), dicalcium_phosphate solid limiting admissibility.
- Fertilizer: 16 May broadcast (col 4 = 13.8), 17 May band (1.65 ... 5.0 ... 0.05 m depth, 0.76 m rows);
  deck `runottawa_input_files/management/soil/fertilizer/f25fr98`.
- Solute failures begin ~hour 3649 (day 153), escalate to terminal at 3669.

Questions (read-only, cite file:line on both sides):
1. Is pH ~9.5 with residual H3PO4 physically plausible, or evidence of a Zig defect upstream (e.g. urea
   hydrolysis / NH3 / carbonate source adding OH- without its counter-ion; H3PO4 not re-speciated after a
   pH jump; wrong sign in a phosphate dissociation flux)? Compare the Zig H3PO4 <-> H2PO4 + H+ and
   H2PO4 <-> HPO4 + H+ closure and bounds with `solute.f` (H3PO4 terms; search CH3P / H3PO4 / RH3P).
2. Which process drives layer-0 H+ down over hours 3600-3669? (fertilizer urea hydrolysis `ureaHydrolysis`,
   NH4 nitrification acidity, evaporation concentrating). Legacy analogue and expected pH trajectory.
3. Propose a discriminating check CLAUDE can run from checkpoint 3600 (e.g. which TEMP probe to print).
Write `.agent/adversarial/round_00012_deepseek.md` (≤500 words). Reply `DONE <path>`.

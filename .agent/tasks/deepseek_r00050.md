# DEEPSEEK task — Round 00050 VERIFY DEV-021 (band-sliver molarity guard scope)  [read-only]

Ottawa 1998 d209 h20: after REDIST relayering, layer 10 NH4 band zone fraction = 1.01e-14 holds 6.5e-9 g N
(concentration ~1.8e5 mol m-3 > water 5.55e4 mol m-3). ng aborted on its own water-molarity guard. CLAUDE proposes
DEV-021: the molarity guards skip a zone whose fraction < 1e-12 (no state change). See row in
`audit/intentional-deviations.md`.

(1) In `f77src/redist.f` (~9494-9589 and the band-solute transfer that follows), quote the lines that move band
geometry (WDNHB, DPNHB, VLNHB) and the lines that move band NH4 mass (ZNH4B / ZNH3B etc.). Confirm or refute that the
geometry moves on a different basis than mass, so a band sliver with mass can remain in the donor.
(2) Quote how legacy HOUR1 (~3845) / SOLUTE / NITRO treat a band zone with VLNHB just above vs below ZERO: is the
concentration computed and used (reactions, uptake, transport) or skipped? If legacy USES the huge concentration
in reactions when VLNHB > ZERO, say what ng should do instead.
(3) Verdict: CONFIRM DEV-021 as D2, or name the faithful alternative.
≤400 words → `.agent/adversarial/round_00050_deepseek.md`. Reply `DONE <path>`.

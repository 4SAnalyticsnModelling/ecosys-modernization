# issue-112 — h4556 non-band layer 0 nitrate candidate −1.5464760719549581e-9 g: summed FMN-floored NO3 reduction demand exceeds zone supply

**Status: FIXED & VERIFIED 2026-10-22 (cycle 00003 close-out).** Fix DEV-022 per-layer supply cap
in `soil/microbial/heterotrophic_denitrification_step.zig` (proportional scaling of all acceptor
stages + respiration; 64*eps deadband; test
"DEV-022 layer supply cap keeps denitrification nitrate demand within zone supply").

Cause (cycle 00003): FMN-floored per-population competition shares (nitro.f 1682-1691, summed at
1692 without a <=1 cap) can demand more zone NO3 than supply; legacy REDIST applies the sum
unclamped (redist.f 6218-6220) and dips pools slightly negative (DEV-019 precedent). Basis
equality proven by term dumps; pool 4.133382671876368e-6 g vs demand 4.134932629096317e-6 g
(+3.74e-4 relative).

Validation: from-scratch strict run `audit/runs/ottawa/zig017-verify-dev021-20261021` cleared
h4556 (cap factor 9.996122280942202e-1), hours 4557-4854 clean, 202 daily conservation ledgers
accepted. Current-binary resume confirmation `audit/runs/ottawa/cycle3-confirm-resume4320-20261022b`
replayed parent records 4321-4555 bit-identically (deadband eliminates the 1-ulp event at h4412),
cap decision byte-identical, conservation ledgers 22/22 accepted. Registry: DEV-022
(`audit/intentional-deviations.md`); adversarial revalidation tracked in `.agent/backlog.md` item 1.
Full closure evidence: `audit/experiments/cycle3-confirm-resume-20261022/g3-g5-digest.md`.

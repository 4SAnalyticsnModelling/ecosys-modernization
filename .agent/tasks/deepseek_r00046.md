# DEEPSEEK task — Round 00046 NFZ-RATE AUDIT (from CLAUDE)  [read-only]

r00045 ACCEPTED and fixed (commit fee72fb): SOIL.F 145-157 calls WATSUB/NITRO/SOLUTE/TRNSFR/REDIST once per NFZ
(NFH=4 non-fire hours, WTHR 597), but WTHR 612-622 defines XNPXX=XNPH, XNPSX=XNPXX*XNPS, XNPRX=XNPXX*XNPR,
XNPSRX=XNPXX*XNPS*XNPRS WITHOUT the XNFH factor (unlike XNPHX=XNPH*XNFH, XNPGX, XNPYX, XNPZX, XNPQX). So any
state-fraction flux scaled by XNPXX/XNPSX/XNPRX/XNPSRX acts NFH times per hour. ng's snowpack meltwater release was
scaled by the hour fraction (≈63%/h vs legacy ≈98%/h); now 1−exp(−NFH·dt). Fresh run r00019 restarted from hour 0.

Task: list EVERY use of XNPXX, XNPSX, XNPRX, XNPSRX (and any other hour-step constant lacking XNFH) in f77src
(watsub.f, trnsfr.f, trnsfrs.f, hour1.f, redist.f, …): file:line, the quantity (flux of what), and whether it is a
rate×time (dimensionally hourly rate — then NFH repetition would be WRONG to replicate, flag it) or a fraction of a
state (then NFH repetition matters). For each, find the ng equivalent (file:line) and state whether ng applies the
same per-hour total. Rank the mismatches by likely impact on Ottawa water/heat/solutes. ≤500 words, table →
`.agent/adversarial/round_00046_deepseek.md`. Reply `DONE <path>`.

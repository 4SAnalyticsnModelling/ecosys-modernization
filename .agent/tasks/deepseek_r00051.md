# DEEPSEEK task — Round 00051 BAND SLIVER: which legacy process touches a ~1e-14 NH4 band zone  [read-only]

DEV-021 lets the molarity guard pass, but at Ottawa 1998 d209 h20 ng now loses 3.3e-11 g N from soil layer 10
(layer-scope closure) while that layer's NH4 band zone has fraction 1.01e-14 holding 6.5e-9 g N (~1.8e5 mol m-3).
I am instrumenting ng to localize. In parallel, from `f77src/` give the legacy treatment of a band zone with
VLNHB ≈ 1e-14 (> ZERO=1e-15 but VOLW*VLNHB << ZEROS2) in each of:
(1) TRNSFR / trnsfr.f band<->non-band diffusive exchange of NH4/NH3 (the XNH4B/ZNH4B exchange term, any VLNHB or
    VOLWNB gate, any limiter by available mass);
(2) NITRO nitrification / microbial NH4 uptake from the band (FNH4B/FNB4 weighting, any gate);
(3) UPTAKE root NH4 uptake from band (any VLNHB/VOLWNB gate);
(4) SOLUTE band NH4<->NH3 speciation and band NH3 volatilization/gas exchange (solute.f ~397 and the band gas
    terms in trnsfr.f / redist.f).
For each: quote the gate line (file:line) and state whether the sliver is SKIPPED, or used and how its flux is
bounded. ≤450 words → `.agent/adversarial/round_00051_deepseek.md`. Reply `DONE <path>`.

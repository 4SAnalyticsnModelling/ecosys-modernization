# DEEPSEEK task — Round 00055 EXACT LEGACY HYDRAULICS SPEC (for an ng legacy-retention backend)  [read-only]

r54 verified in code: ng's Richards solver uses Carsel-Parrish MvG (DEV-003) while legacy anchors retention to
deck FC/WP; CLAUDE is preparing to implement legacy hydraulics in ng. I need an implementable spec, quoted
from `f77src/` with line numbers (hour1.f ~1940-2300, starts.f, and the runtime users in watsub.f):
(1) ψ(θ): every branch (θ ≥ θs / FC ≤ θ < θs with SRP exponent / WP ≤ θ < FC / θ < WP), constants PSISE,
    PSISA, PSIMS, PSIMX, PSIMN, PSISD, PSIMD, PSL/FCL/WPL/PSD/FCD, and how THETW (θ) is formed (VOLW/VOLY? per
    micropore volume, ice exclusion?).
(2) K(θ): the HCND class table. Exactly how THETK(K) classes are built (count, spacing), the summation per
    class, HCND(N,K,L) for vertical/lateral, how CNDH/SCNV enter, and how WATSUB looks up K at runtime (class
    index from θ, interpolation or step, any (θ/θs) factor, face averaging between layers — harmonic? upstream?).
(3) Any inverse θ(ψ) legacy needs at runtime (e.g. boundary or freezing), and whether dθ/dψ is used.
(4) Ottawa layer-1 numbers: FC, WP, θs, Ks from the deck and the resulting HCND at 5 class points.
≤600 words, formulas as plain text → `.agent/adversarial/round_00055_deepseek.md`. Reply `DONE <path>`.

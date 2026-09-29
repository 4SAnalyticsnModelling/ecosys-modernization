# DEEPSEEK task — Round 00017 GAP ANALYSIS (from CLAUDE)

r00016 ACCEPTs recorded. Fresh strict run r00007 (commit 627634a) is running from hour 0.

Remaining relayering gap to quantify for the Ottawa deck (no code edits; analysis + proposal):
1. Read the deck's IERSNG (erosion/disturbance mode) — `C:\ecosys-build\runs\r00007-strict\deck\runottawa_input_files\landscape\f25si98`
   and how ng parses it (`site_by_cell[cell].erosion_mode`, geometry_disturbance_transaction.zig:153-159).
2. Legacy redist.f 8172-8209: when IFLGM=0 (no DVOLI anywhere in the column this hour) soil DDLYRX = DLYRI − DLYR1
   and DDLYRY = DDLYRX (8190-8191), i.e. legacy MOVES MATERIAL to restore each layer to its initial thickness;
   when IFLGM=1 it restores geometry only (DDLYRY, 8188/8199). ng implements neither. With freeze-thaw now
   geometry-only in ng, a layer thickened by ice keeps its thickness until thaw reverses it. Does legacy
   material-restoration in IFLGM=0 hours move soil between layers after a freeze-thaw season (residual
   DLYR ≠ DLYRI)? Estimate magnitude for Ottawa (1 cm top layer; seasonal DVOLI).
3. Recommend: port (a) DDLYRY geometry restore, (b) IFLGM=0 material restore, both, or neither for Ottawa
   comparability; give the minimal Zig change sites (file:line).
≤350 words → `.agent/adversarial/round_00017_deepseek.md`. Reply `DONE <path>`.

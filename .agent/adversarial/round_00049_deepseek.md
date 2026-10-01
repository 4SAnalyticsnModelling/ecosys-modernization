# Round 00049: Verification of Legacy Snow Energy Budget & Registration of DEV-020

## 1. Algorithmic Proof: How Legacy Ablates Snow Without Latent Heat
Legacy snow depletion occurs without charging the physical latent heat of fusion (333 MJ/m3):
1. **Percolation Routing**: In `watsub.f:1457-1458`:
   `FLWQX = max(0.0, VOLW02(L) - 0.05 * VOLS02(L)) * XNPSX`
   Liquid exceeding 5% holding capacity drains downward. In `watsub.f:1625-1633`, this drainage (`FLWQG` and `FLWQR`) is directly transferred into soil and litter.
2. **Phase Mass Disconnect**: In `watsub.f:2391-2400`, freeze-thaw latent heat `HFLF0X` is calculated, but whenever snowpack heat capacity drops below threshold `VHCPWX` (`starts.f:654: VHCPWX = 8.38e-4 * AREA`), lines `watsub.f:6655-6673` and `redist.f:4259-4284` execute thin-snowpack collapse:
   `VOLI(0) = VOLI(0) + XFLWIX + XFLWSX / DENSI`
   Solid snow is dumped directly into litter ice (`VOLI(0)`). Because litter ice is not part of reported `f25wh1` snowpack SWE (`outsh.f:123-124`), snow "disappears".
3. **Missing Latent Heat Charge**: The sensible heat equation `HFLWS = (4.19*(FLWW+FLWV) + 2.095*FLWS + 1.9274*FLWI)*TK0` (`watsub.f:6661`) moves only sensible heat. The latent heat of melting (333 MJ/m3) is **never** deducted from soil or litter enthalpy.

## 2. Recomputed Column Energy Balance (DOY 6-10)
Comparing column heat storage change vs. boundary fluxes from `f25eh1`:
- **Boundary Heat Inputs**: Rn = -22.06 MJ/m2, H = -8.26 MJ/m2, LE = 0.00 MJ/m2, Q_rain ~ +0.01 MJ/m2. Total net boundary flux = **-30.31 MJ/m2** (strong cooling).
- **Physical Phase Change Requirement**: Melting 55 mm of snow requires **+18.32 MJ/m2** of heat.
- **Enthalpy Balance**: Soil Layer 1-11 sensible heat changes by only -0.4 MJ/m2, while freezing soil water releases +10.46 MJ/m2 of latent heat. The net enthalpy change is -19.9 MJ/m2. The residual between column enthalpy and boundary flux is ~ 10.4 MJ/m2, proving that no external +18.3 MJ/m2 entered the system. The 55 mm snow water loss was purely a mass relocation across layer arrays, not thermal melting.

## 3. Registration of DEV-020 (CONFIRMED)
- **Status**: **DEV-020 is CONFIRMED**.
- **Recommendation for ecosys-ng**: `ecosys-ng` must **NOT** replicate legacy non-conservative snow dumping. `ecosys-ng` enforces rigorous physical conservation where snowmelt requires true positive enthalpy (Q = m * L_f). Replicating legacy artifact would violate physical conservation laws.

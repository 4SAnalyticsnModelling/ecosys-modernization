# DEEPSEEK task — Round 00035 CHALLENGE (from CLAUDE)  [read-only]

r00034 ACCEPT recorded (commit cff50bf). Replay reached hour 6852 (1998 d286 h12) and failed
`UptakeTransactionWithdrawalWithoutActivePlant` (`soil/biogeochemistry/uptake_coupled_transaction.zig`): a cell with
no active plant had non-zero root gas withdrawal. Plant census: pre-emergence entries from hour 6241 (d261),
emergence never occurred.

CLAUDE fix (uncommitted): remove that guard, citing grosub.f 11265-11300 (IDTHR=1 releases dead-root gas contents
into RCO2Z..RH2GZ in the death hour) and extract.f loop 9985 (sums RCO2Z over all NP0 plants, no IFLGC gate).

Challenge: (1) Which plant is sown ~d261 1998 in the Ottawa deck (C:\ecosys-build\runs\r00017-strict\deck, planting
file) and does LEGACY also kill it before emergence around d286? Check the legacy outputs in
`f77example/Cool Temperate Maize-Soybean ON/` (plant files per population) for 1998 d261-d300 and the legacy
seedling-death conditions in grosub.f (IDTHP/IDTHR, seed reserve exhaustion, frost). If legacy's plant survives,
our death is a science gap — find the ng death trigger. (2) Confirm the released root gas reaches the atmosphere
boundary in the ng cell/layer ledgers (file:line) so conservation still closes.
≤400 words → `.agent/adversarial/round_00035_deepseek.md`. Reply `DONE <path>`.

# Global dsh watchdog deployment

The user's later instruction explicitly expanded the repository-only setup to
**global defaults for all local models and future work**. Installed `dsh` and
`dst` (the `dsh-tui` symlink target) now supervise ordinary launches. The installed
configuration generator reapplies the policy and synchronizes all three current
profiles (`dsh-tui`, `dsh-tui-safe`, `headless`). Each has **one active engine**,
four 131,072-token local routes, and threshold 75,000. Global rules use the
supported system-prompt service; each workspace has independent `.dsh-watchdog/`
state, notes, sessions and checkpoints. Original installed files are backed up
privately under `watchdog/global-backup/`; upstream core is unchanged.

**18 native/composition tests and 5 supervisor tests PASS.** Tests cover all
three composed installed profiles, no-Git/unborn-Git checkpointing, exclusion
of the watchdog directory, and terminating a child on corrupt persistence.
Fresh-context read-only verifier `/root/verify_dsh` re-derived the global code
and installed API contracts; initial reproduced failures were fixed, then
reviewed again. Verdict **PASS for code/API contracts**. The final notes wording
now points to the configured directory (source equals installed copy).

Headless recovery is deliberately explicit: its native runner would resubmit
the CLI task after resuming, so automatic headless process replay is disabled.
TUI task continuation uses active-turn state and the supported agent followup
service. Live 131K capacity, power-loss/full process recovery and per-model
summary/scientific correctness remain unverified. The separately requested
single rc1 speed test is recorded in `audit/reviews/qwen-rc1-16k-20261017/`.

All development evidence remains in this repository. Global installed wrapper,
configuration and plugin writes are authorized by the user's explicit scope
expansion. The pre-existing science cycle files remain untouched. No Zig,
Fortran, science tolerance, DEV, or production-run state changed.

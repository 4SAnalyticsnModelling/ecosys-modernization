#!/usr/bin/env python3
"""Extract mineral-N failure dumps from an Ottawa stderr log."""
import sys, re
from pathlib import Path

pat = re.compile(
    r"ammonium breakdown: pool_before=(\S+) ammonia_oxidation=(\S+) autotrophic_ammonium_oxidation=(\S+) candidate=(\S+) operation_scale=(\S+)"
    r"|nitrate breakdown: pool_before=(\S+) nitrite_oxidation=(\S+) nitrate_reduction=(\S+) candidate=(\S+) operation_scale=(\S+)"
    r"|rejected negative candidate: error=(\S+) value=(\S+) operation_scale=(\S+) roundoff_limit=(\S+)"
    r"|failing site: (\S+) layer=(\d+)"
    r"|hourly science failed: execution=(\d+) scenario=(\d+) scenario_repeat=(\d+) scene=(\d+) scene_hour=(\d+) total_hour=(\d+) year=(\d+) day_of_year=(\d+) month=(\d+) day=(\d+) hour=(\d+) error=(\S+)"
)
path = Path(sys.argv[1])
lines = []
for lineno, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
    if "state_update" in line or "hourly science failed" in line:
        m = pat.search(line)
        if m:
            kind = "ammonium" if m.group(1) else "nitrate" if m.group(6) else "rejected" if m.group(11) else "site" if m.group(15) else "hourly"
            lines.append((lineno, kind, line.strip()))
for lineno, kind, line in lines[:40]:
    print(f"{lineno}: {line[:400]}")
    print()
print(f"total={len(lines)}")

# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Report the Status line of every audit/issues/*.md so the open set is exact (plan P0.6).

Report-only: it never edits an issue. The top `Status:` line (within the first 12 lines) is
authoritative; a file without one, or with a later contradicting Status/Resolution line, is
listed for normalization. Classification is by keyword and is a worklist, not a verdict.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys

from workflow import ROOT

CLOSED = re.compile(r"\b(FIXED|RESOLVED|CLOSED|WITHDRAWN|DUPLICATE|NOT A DEFECT|INVALID|SUPERSEDED)\b", re.I)
OPEN = re.compile(r"\b(OPEN|NOT_ASSESSED|LOCALI[SZ]ED|IN PROGRESS|BLOCKED|PARTIAL|UNRESOLVED|SUSPECTED|QUEUED)\b", re.I)
STATUS = re.compile(r"^\s*(?:\*\*)?Status(?:\*\*)?\s*:\s*(.+)$", re.I)


def classify(text: str) -> str:
    head = text[:160]
    o, c = OPEN.search(head), CLOSED.search(head)
    if o and c:
        return "open" if o.start() < c.start() else "closed"
    return "closed" if c else "open" if o else "unclear"


def scan(root: Path) -> dict:
    rows = []
    for p in sorted((root / "audit/issues").glob("issue-*.md")):
        lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
        top = next(((i + 1, m.group(1).strip()) for i, l in enumerate(lines[:12]) if (m := STATUS.match(l))), None)
        later = [(i + 1, m.group(1).strip()) for i, l in enumerate(lines) if i >= 12 and (m := STATUS.match(l))]
        state = classify(top[1]) if top else "missing"
        conflict = bool(top and later and classify(later[-1][1]) not in (state, "unclear"))
        rows.append({"file": p.name, "status_line": top[0] if top else None, "status": top[1][:200] if top else None,
                     "class": state, "later_status_conflicts": conflict,
                     "later_status": later[-1][1][:200] if later else None})
    counts = Counter(r["class"] for r in rows)
    return {"total": len(rows), "counts": dict(counts),
            "needs_normalization": [r["file"] for r in rows if r["class"] in ("missing", "unclear") or r["later_status_conflicts"]],
            "issues": rows,
            "limitations": "Keyword classification of the top Status line; a human/agent must confirm each normalization."}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=ROOT)
    ap.add_argument("--summary", action="store_true", help="omit the per-issue rows")
    a = ap.parse_args()
    r = scan(a.root.resolve())
    if a.summary:
        r.pop("issues")
    print(json.dumps(r, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

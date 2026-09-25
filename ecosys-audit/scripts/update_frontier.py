# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""The only writer of .agent/frontier.json (plan P5.5).

record  : update simulation_frontier / current_failure_hour from a run summary.json (any mode).
promote : set verified_frontier from a STRICT campaign, only when all hold under ONE binding:
          divcheck within rules (approved rules), no conservation breach, no unexplained solver
          fallback, restart validation PASS, and the run started from hour 0.
Bookkeeping over recorded artifacts; it does not re-derive them and is not a release gate.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import time

from workflow import ROOT, ProtocolError, atomic, encoded, file_digest, inside, load, relative

FRONTIER = ".agent/frontier.json"


def art(root: Path, value: str) -> tuple[dict, dict]:
    p = inside(root, value)
    return load(p), {"path": relative(root, p), "sha256": file_digest(p)}


def binding_id(obj: dict):
    b = obj.get("binding") or obj.get("evidence_binding")
    return b.get("binding_id") if isinstance(b, dict) else obj.get("binding_id")


def record(root: Path, summary_path: str) -> dict:
    f = load(root / FRONTIER)
    s, ref = art(root, summary_path)
    last = s.get("last_completed_hour")
    if not isinstance(last, int):
        raise ProtocolError("summary.last_completed_hour must be an integer")
    f.update({"simulation_frontier": last, "current_failure_hour": s.get("failure_hour"),
              "last_checkpoint_key": s.get("last_checkpoint_key"), "evidence_binding": s.get("binding")})
    f["simulation_frontier_note"] = f"From {ref['path']} (mode {s.get('mode')})."
    f["history"].append({"time": time.time(), "op": "record", "simulation_frontier": last, "summary": ref})
    atomic(root / FRONTIER, encoded(f))
    return {"status": "RECORDED", "simulation_frontier": last, "verified_frontier": f["verified_frontier"]}


def promote(root: Path, summary_path: str, divcheck_path: str, restart_path: str) -> dict:
    f = load(root / FRONTIER)
    s, sref = art(root, summary_path)
    d, dref = art(root, divcheck_path)
    r, rref = art(root, restart_path)
    problems = []
    if s.get("mode") != "strict":
        problems.append("campaign mode is not strict")
    if s.get("start_hour") not in (0, 1):
        problems.append("campaign did not start from hour 0 (replays can never promote)")
    if s.get("conservation_breaches") != 0:
        problems.append("conservation breaches not recorded as 0")
    if s.get("solver_fallbacks_unexplained") != 0:
        problems.append("unexplained solver fallbacks not recorded as 0")
    if not d.get("rules_approved"):
        problems.append("divcheck rules are not approved")
    if r.get("status") != "PASS":
        problems.append("restart validation is not PASS")
    ids = {binding_id(s), binding_id(d), binding_id(r)}
    if None in ids or len(ids) != 1:
        problems.append(f"artifacts are not bound to one evidence binding: {sorted(map(str, ids))}")
    if problems:
        return {"status": "REFUSED", "problems": problems}
    candidates = [s.get("last_completed_hour")]
    if d.get("status") != "WITHIN_RULES":
        candidates.append(d.get("last_verified_hour"))
    candidates.append(r.get("last_equivalent_hour"))
    if not all(isinstance(c, int) for c in candidates):
        return {"status": "REFUSED", "problems": ["summary/divcheck/restart must give integer hours "
                                                  "(last_completed_hour, last_verified_hour, last_equivalent_hour)"]}
    verified = min(candidates)
    old = f["verified_frontier"]
    f.update({"verified_frontier": verified, "evidence_binding": s.get("binding"),
              "verified_frontier_note": f"Promoted from {sref['path']}."})
    f["history"].append({"time": time.time(), "op": "promote", "from": old, "to": verified,
                         "binding_id": binding_id(s), "evidence": [sref, dref, rref]})
    atomic(root / FRONTIER, encoded(f))
    return {"status": "PROMOTED", "from": old, "to": verified, "advanced": verified > old}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=ROOT)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("show")
    r = sub.add_parser("record")
    r.add_argument("--summary", required=True)
    p = sub.add_parser("promote")
    p.add_argument("--summary", required=True)
    p.add_argument("--divcheck", required=True)
    p.add_argument("--restart", required=True)
    a = ap.parse_args()
    root = a.root.resolve()
    try:
        if a.cmd == "show":
            out = load(root / FRONTIER)
            out.pop("history", None)
        elif a.cmd == "record":
            out = record(root, a.summary)
        else:
            out = promote(root, a.summary, a.divcheck, a.restart)
        print(json.dumps(out, indent=2))
        return 1 if out.get("status") == "REFUSED" else 0
    except (OSError, ValueError, KeyError, ProtocolError) as e:
        print(json.dumps({"status": "BLOCKED", "error": str(e)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

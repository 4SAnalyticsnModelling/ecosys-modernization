# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Create a failure packet .agent/failures/F-NNNNN/ (spec section 18) from recorded evidence.

Deterministic: it copies/pointers evidence and extracts the named source ranges; it does not
diagnose. Rejected hypotheses from earlier packets with the same --signature are carried
forward so an agent does not retry them. Fields not supplied are written as "UNKNOWN".
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

from workflow import ROOT, ProtocolError, encoded, file_digest, inside, relative

FIELDS = ["first_failing_timestep", "last_verified_timestep", "first_divergent_state", "subsystem",
          "exact_error", "relevant_variables", "candidate_zig", "candidate_fortran", "checkpoint", "binding_id"]


def next_id(failures: Path) -> str:
    nums = [int(m.group(1)) for p in failures.glob("F-*") if (m := re.fullmatch(r"F-(\d{5})", p.name))]
    return f"F-{(max(nums) + 1 if nums else 1):05d}"


def zig_range(root: Path, spec: str) -> str:
    m = re.fullmatch(r"(.+):(\d+)-(\d+)", spec)
    if not m:
        raise ProtocolError(f"--zig expects path:N-M, got {spec!r}")
    path, a, b = inside(root, m.group(1)), int(m.group(2)), int(m.group(3))
    if b < a or b - a > 400:
        raise ProtocolError(f"--zig range must be 1..400 lines: {spec}")
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    body = "\n".join(f"{i:6d}  {lines[i - 1]}" for i in range(a, min(b, len(lines)) + 1))
    return f"=== {relative(root, path)}:{a}-{b} (sha256 {file_digest(path)})\n{body}\n"


def fortran_range(root: Path, spec: str) -> str:
    m = re.fullmatch(r"([\w.]+\.f):(\d+)-(\d+)", spec)
    if not m:
        raise ProtocolError(f"--fortran expects file.f:N-M, got {spec!r}")
    if int(m.group(3)) - int(m.group(2)) > 400:
        raise ProtocolError("--fortran range must be <=400 lines")
    p = subprocess.run(["uv", "run", "ecosys-audit/scripts/f77query.py", "show", m.group(1), "--lines",
                        f"{m.group(2)}-{m.group(3)}"], cwd=root, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=300)
    if p.returncode:
        raise ProtocolError(f"f77query show failed: {p.stderr[:400]}")
    return f"=== f77src/{spec} (via f77query.py show)\n{p.stdout}\n"


def carried_rejections(failures: Path, signature: str) -> list[str]:
    out = []
    for d in sorted(failures.glob("F-*")):
        meta = d / "packet.json"
        if meta.exists() and json.loads(meta.read_text(encoding="utf-8")).get("signature") == signature:
            text = (d / "rejected-hypotheses.md").read_text(encoding="utf-8")
            out += [l for l in text.splitlines() if l.startswith("- ")]
    return list(dict.fromkeys(out))


def build(root: Path, a) -> dict:
    failures = root / ".agent/failures"
    failures.mkdir(parents=True, exist_ok=True)
    pid = next_id(failures)
    d = failures / pid
    d.mkdir()
    values = {f: getattr(a, f) or "UNKNOWN" for f in FIELDS}
    summary = None
    if a.summary:
        sp = inside(root, a.summary)
        summary = json.loads(sp.read_text(encoding="utf-8-sig"))
        values["first_failing_timestep"] = a.first_failing_timestep or str(summary.get("failure_hour", "UNKNOWN"))
        values["exact_error"] = a.exact_error or str(summary.get("error", summary.get("failure_type", "UNKNOWN")))
        values["binding_id"] = a.binding_id or str((summary.get("binding") or {}).get("binding_id", "UNKNOWN"))
    rows = "\n".join(f"| {f.replace('_', ' ').capitalize()} | {values[f]} |" for f in FIELDS)
    (d / "summary.md").write_text(
        f"# FAILURE PACKET: {pid}\n\nSignature: `{a.signature}`\nTask: {a.task or 'UNKNOWN'}\n\n"
        f"| Field | Value |\n|---|---|\n{rows}\n| Recent changes | see `recent-diff.patch` |\n"
        f"| Previous attempts | see `rejected-hypotheses.md` |\n", encoding="utf-8")
    state = json.loads(inside(root, a.state_values).read_text(encoding="utf-8-sig")) if a.state_values else {}
    (d / "state-values.json").write_bytes(encoded(state))
    (d / "relevant-zig.txt").write_text("".join(zig_range(root, s) for s in a.zig) or "none supplied\n", encoding="utf-8")
    (d / "relevant-fortran.txt").write_text("".join(fortran_range(root, s) for s in a.fortran) or "none supplied\n", encoding="utf-8")
    diff = subprocess.run(["git", "diff", "HEAD", "--", "ecosys-ng/src", "ecosys-ng/build.zig"], cwd=root,
                          capture_output=True, timeout=300).stdout
    (d / "recent-diff.patch").write_bytes(diff)
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True).stdout.strip()
    (d / "hypotheses.md").write_text("# Open hypotheses\n\n" + "".join(f"- {h}\n" for h in a.hypothesis) or "", encoding="utf-8")
    rejected = carried_rejections(failures, a.signature) + [f"- {h}" for h in a.rejected]
    (d / "rejected-hypotheses.md").write_text("# Rejected hypotheses (carried forward by signature)\n\n" +
                                              "\n".join(dict.fromkeys(rejected)) + "\n", encoding="utf-8")
    pointers = [f"commit: {head}"] + [f"log: {p} sha256={file_digest(inside(root, p))}" for p in a.log]
    if a.summary:
        pointers.append(f"summary: {a.summary} sha256={file_digest(inside(root, a.summary))}")
    (d / "log-pointer.txt").write_text("\n".join(pointers) + "\n", encoding="utf-8")
    meta = {"packet": pid, "signature": a.signature, "task": a.task, "commit": head, "fields": values,
            "carried_rejections": len(rejected) - len(a.rejected)}
    (d / "packet.json").write_bytes(encoded(meta))
    return {"status": "CREATED", "path": relative(root, d), **meta}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=ROOT)
    ap.add_argument("--signature", required=True, help="Stable failure signature, e.g. 'HourlyCellConservationFailure:Ca:L2'")
    ap.add_argument("--task")
    ap.add_argument("--summary", help="run summary.json (fills failure hour, error, binding)")
    for f in FIELDS:
        ap.add_argument("--" + f.replace("_", "-"), dest=f)
    ap.add_argument("--state-values", help="JSON file with the relevant state values")
    ap.add_argument("--zig", action="append", default=[], help="path:N-M, repeatable")
    ap.add_argument("--fortran", action="append", default=[], help="file.f:N-M, repeatable")
    ap.add_argument("--log", action="append", default=[], help="raw log path, repeatable (pointer + hash only)")
    ap.add_argument("--hypothesis", action="append", default=[])
    ap.add_argument("--rejected", action="append", default=[])
    a = ap.parse_args()
    try:
        print(json.dumps(build(a.root.resolve(), a), indent=2))
        return 0
    except (OSError, ValueError, ProtocolError, subprocess.SubprocessError) as e:
        print(json.dumps({"status": "BLOCKED", "error": str(e)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

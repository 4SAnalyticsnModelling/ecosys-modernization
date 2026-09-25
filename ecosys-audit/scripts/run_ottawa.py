# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Stage and run one Ottawa ecosys-ng job; write a spec section 17 summary.json (plan P2.9).

Modes: strict (fatal on first failure; the only mode that can promote the frontier),
survey (--survey-conservation; hints, never evidence), dump (refused until the P2.2 state-dump
build option exists). The binary resumes from any checkpoint files present in its deck, so a
strict hour-0 run is staged into a fresh copy with NO checkpoints; --restart-from copies one
checkpoint set in explicitly (a replay: provisional-diagnostic, never promotion evidence).

Holds the exclusive machine lock (.agent/locks/machine.lock), refuses on low disk space or a
slow D: read (a faulted D: presents as a zero-CPU hang), and binds the run to its evidence binding.
Summary fields it cannot parse are null; update_frontier.py promote refuses nulls.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid

from workflow import ROOT, ProtocolError, atomic, encoded, file_digest, inside, load, lock, relative
from evidence_binding import compute as compute_binding

DECK = "ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON"
CHECKPOINT = re.compile(r"^(\d+)\.grid_and_plants\.bin$")
LONG_RUN_SECONDS = 3 * 3600


def checkpoints(tree: Path) -> dict[int, list[Path]]:
    """hour -> checkpoint files of that hour (the main file plus siblings sharing the '<hour>.' prefix)."""
    out: dict[int, list[Path]] = {}
    for f in tree.rglob("*.grid_and_plants.bin"):
        m = CHECKPOINT.match(f.name)
        if m:
            h = int(m.group(1))
            out[h] = sorted(p for p in f.parent.glob(f"{h}.*") if p.is_file())
    return out


def io_probe(path: Path, limit_s: float) -> float:
    start = time.perf_counter()
    with path.open("rb") as f:
        f.read(1 << 20)
    elapsed = time.perf_counter() - start
    if elapsed > limit_s:
        raise ProtocolError(f"D: read probe took {elapsed:.2f}s (> {limit_s}s); drive may be faulted, refusing to start")
    return elapsed


def parse_outcome(stdout: Path, stderr: Path) -> dict:
    """Heuristic parse of the error name and failing hour. Confidence is reported, not assumed."""
    text = ""
    for p in (stdout, stderr):
        if p.exists():
            with p.open("rb") as f:
                f.seek(max(0, p.stat().st_size - (1 << 20)))
                text += f.read().decode("utf-8", errors="replace")
    errs = re.findall(r"error[:\s]+([A-Z][A-Za-z0-9_]+)", text)
    hours = re.findall(r"\bhour\s*[=:#]?\s*(\d{1,6})\b", text, re.I)
    return {"error": errs[-1] if errs else None, "failure_hour": int(hours[-1]) if errs and hours else None,
            "parse_confidence": "heuristic-last-match"}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=ROOT)
    ap.add_argument("--mode", choices=["strict", "survey", "dump"], required=True)
    ap.add_argument("--exe", type=Path, required=True, help="built ecosys_ng.exe (copied into the staged deck)")
    ap.add_argument("--build-mode", required=True, choices=["Debug", "ReleaseSafe", "ReleaseFast"])
    ap.add_argument("--build-option", action="append", default=[])
    ap.add_argument("--deck", default=DECK)
    ap.add_argument("--run-id", default=None)
    ap.add_argument("--restart-from", help="<prior-run-id>:<hour> checkpoint set to replay from")
    ap.add_argument("--threads", type=int)
    ap.add_argument("--timeout", type=float, required=True, help="seconds")
    ap.add_argument("--full-run-justification", help="required when --timeout exceeds 3 h (plan section 5)")
    ap.add_argument("--min-free-gb", type=float, default=20)
    ap.add_argument("--io-probe-limit", type=float, default=2.0)
    a = ap.parse_args()
    root = a.root.resolve()
    try:
        if a.mode == "dump":
            raise ProtocolError("dump mode needs the P2.2 Zig state-dump build option, which does not exist yet")
        if a.timeout > LONG_RUN_SECONDS and not (a.full_run_justification and len(a.full_run_justification) > 20):
            raise ProtocolError("a run longer than 3 h is a full run: pass --full-run-justification (plan section 5)")
        run_id = a.run_id or f"{time.strftime('%Y%m%d-%H%M%S')}-{a.mode}-{uuid.uuid4().hex[:6]}"
        stage = inside(root, f"evidence/runs/{run_id}")
        logs = f"audit/runs/ottawa/{run_id}"
        deck_src = inside(root, a.deck)
        exe = a.exe.resolve(strict=True)
        free_gb = shutil.disk_usage(root).free / 1e9
        if free_gb < a.min_free_gb:
            raise ProtocolError(f"only {free_gb:.1f} GB free (< {a.min_free_gb}); refusing to start")
        probe = io_probe(next(p for p in deck_src.rglob("*") if p.is_file()), a.io_probe_limit)
        with lock(root / ".agent/locks/machine.lock"):
            binding = compute_binding(root, a.deck, a.build_mode, a.build_option)
            deck = stage / "deck"
            # Prior outputs (and their checkpoint siblings) are never staged; the binary writes a fresh tree.
            shutil.copytree(deck_src, deck, ignore=shutil.ignore_patterns("runottawa_output_files", "*.grid_and_plants.bin"))
            (deck / "runottawa_output_files").mkdir(exist_ok=True)
            pre = checkpoints(deck)
            start_hour = 0
            if a.restart_from:
                prior, hour = a.restart_from.rsplit(":", 1)
                source = checkpoints(inside(root, f"evidence/runs/{prior}/deck")).get(int(hour))
                if not source:
                    raise ProtocolError(f"no checkpoint set for hour {hour} in run {prior}")
                for f in source:
                    target = deck / f.parent.relative_to(inside(root, f"evidence/runs/{prior}/deck")) / f.name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(f, target)
                start_hour = int(hour)
            elif pre:
                raise ProtocolError(f"staged deck already holds checkpoints {sorted(pre)}; a strict hour-0 run needs none")
            shutil.copy2(exe, deck / exe.name)
            argv = [str(deck / exe.name)]
            if a.mode == "survey":
                argv.append("--survey-conservation")
            if a.threads:
                argv += ["--threads", str(a.threads)]
            argv.append("runottawa")
            started = time.time()
            p = subprocess.run([sys.executable, str(Path(__file__).resolve().parent / "run_logged.py"), "--root", str(root),
                                "--cwd", str(deck), "--out", logs, "--timeout", str(a.timeout), "--", *argv],
                               cwd=root, capture_output=True, text=True, encoding="utf-8", errors="replace",
                               timeout=a.timeout + 300)
            receipt = load(root / logs / "receipt.json")
            cps = checkpoints(deck)
            outcome = parse_outcome(root / logs / "stdout.log", root / logs / "stderr.log")
            code = receipt.get("exit_code")
            status = "TIMED_OUT" if receipt.get("status") == "TIMED_OUT" else "COMPLETE" if code == 0 else "FAIL"
            last_cp = max(cps) if cps else None
            summary = {
                "schema_version": 1, "run_id": run_id, "mode": a.mode, "status": status, "exit_code": code,
                "start_hour": start_hour, "restart_from": a.restart_from,
                "evidence_class": "replay-provisional-diagnostic" if a.restart_from else ("hint-not-evidence" if a.mode == "survey" else "strict"),
                "last_checkpoint_key": last_cp,
                "last_completed_hour": (outcome["failure_hour"] - 1) if outcome["failure_hour"] else None,
                "failure_hour": outcome["failure_hour"], "error": outcome["error"],
                "parse_confidence": outcome["parse_confidence"],
                "conservation_breaches": None, "solver_fallbacks_unexplained": None,
                "binding": binding, "exe_sha256": file_digest(exe), "io_probe_seconds": round(probe, 4),
                "wall_seconds": round(time.time() - started, 1), "full_run_justification": a.full_run_justification,
                "full_log": f"{logs}/stdout.log", "receipt": f"{logs}/receipt.json", "staged_deck": relative(root, deck),
                "limitations": ("failure_hour/error are heuristic parses; conservation_breaches and "
                                "solver_fallbacks_unexplained stay null until a validator fills them, so this summary alone "
                                "can never promote the frontier."),
            }
            atomic(root / logs / "summary.json", encoded(summary))
            if a.full_run_justification:
                wf_path = root / ".agent/workflow.json"
                wf = load(wf_path)
                wf.setdefault("full_runs", {}).setdefault("zig", 0)
                wf["full_runs"]["zig"] += 1
                wf.setdefault("full_run_justifications", []).append({"run_id": run_id, "text": a.full_run_justification})
                atomic(wf_path, encoded(wf))
        print(json.dumps({k: summary[k] for k in ("run_id", "status", "mode", "failure_hour", "error",
                                                  "last_checkpoint_key", "wall_seconds")} |
                         {"summary": f"{logs}/summary.json"}, indent=2))
        return 0 if status == "COMPLETE" else 1
    except (OSError, ValueError, KeyError, StopIteration, ProtocolError, subprocess.SubprocessError) as e:
        print(json.dumps({"status": "BLOCKED", "error": str(e)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

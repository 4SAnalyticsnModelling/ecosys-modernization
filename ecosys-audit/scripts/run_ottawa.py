# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Stage one strict/survey Ottawa job with source/build identity and restart provenance.
Exit zero is execution success only; science completion requires terminal/output validation.
Cross-revision replays are diagnostic. Dump mode is unavailable until its writer exists."""
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

try:
    from stage_ottawa_deck import TARGET_BLOB, stage_ottawa_deck
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from stage_ottawa_deck import TARGET_BLOB, stage_ottawa_deck

DECK = "ecosys-ng-prod-examples/Cool Temperate Maize-Soybean ON"
CHECKPOINT = re.compile(r"^(\d+)\.grid_and_plants\.bin$")


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
        raise ProtocolError(f"Input read probe took {elapsed:.2f}s (> {limit_s}s); drive may be faulted, refusing to start")
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
    ap.add_argument("--build-receipt", help="Successful build receipt proving source, mode and executable identity")
    ap.add_argument("--build-option", action="append", default=[])
    ap.add_argument("--deck", default=DECK)
    ap.add_argument("--run-id", default=None)
    ap.add_argument("--staged-deck", type=Path, default=None, help="Directory for staged deck (default: evidence/runs/<run-id>/deck)")
    ap.add_argument("--out", type=str, default=None, help="Directory for run logs and receipt under audit/runs (default: audit/runs/ottawa/<run-id>)")
    ap.add_argument("--lock-file", type=Path, default=None, help="Machine lock path (default: .agent/locks/machine.lock)")
    ap.add_argument("--restart-from", help="<prior-run-id>:<hour> checkpoint set to replay from")
    ap.add_argument("--threads", type=int)
    ap.add_argument("--timeout", type=float, default=None,
                    help="Deprecated compatibility argument; runs always proceed to natural completion")
    ap.add_argument("--full-run-justification", help="Optional explanation of campaign scope")
    ap.add_argument("--min-free-gb", type=float, default=20)
    ap.add_argument("--io-probe-limit", type=float, default=2.0)
    a = ap.parse_args()
    a.timeout = None  # Legacy timeout options cannot interrupt autonomous work.
    root = a.root.resolve()
    try:
        if a.mode == "dump":
            raise ProtocolError("dump mode needs the P2.2 Zig state-dump build option, which does not exist yet")
        run_id = a.run_id or f"{time.strftime('%Y%m%d-%H%M%S')}-{a.mode}-{uuid.uuid4().hex[:6]}"
        stage = inside(root, f"evidence/runs/{run_id}")
        logs = a.out or f"audit/runs/ottawa/{run_id}"
        deck_src = inside(root, a.deck)
        exe = inside(root, str(a.exe)).resolve(strict=True)
        free_gb = shutil.disk_usage(root).free / 1e9
        if free_gb < a.min_free_gb:
            raise ProtocolError(f"only {free_gb:.1f} GB free (< {a.min_free_gb}); refusing to start")
        probe = io_probe(next(p for p in deck_src.rglob("*") if p.is_file()), a.io_probe_limit)
        lock_path = inside(root, str(a.lock_file)) if a.lock_file else (root / ".agent/locks/machine.lock")
        with lock(lock_path):
            binding = compute_binding(root, a.deck, a.build_mode, a.build_option)
            deck = inside(root, str(a.staged_deck)) if a.staged_deck else stage / "deck"
            if deck.exists() and any(deck.iterdir()):
                raise ProtocolError(f"staged deck destination {deck} already exists and is not empty; qualification runs require a fresh directory")
            # Prior outputs (and their checkpoint siblings) are never staged; stage the approved deck
            # with verified blob overwrite (G0-2a, T-00220/T-00221, blob ecf5e61ab453288b1763f81f841729bee34e8426).
            stage_report = stage_ottawa_deck(out_dir=deck, src_dir=deck_src, repo_root=root)
            runottawa_hash = stage_report["runottawa_hash"]
            if runottawa_hash != TARGET_BLOB:
                raise ProtocolError(f"staged runottawa hash mismatch: expected {TARGET_BLOB}, got {runottawa_hash}")
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
            staged_exe_sha256 = file_digest(deck / exe.name)
            build_verified = False
            if a.build_receipt:
                build_receipt = load(inside(root,a.build_receipt))
                build_verified = (build_receipt.get("exit_code") == 0
                    and build_receipt.get("source_digest") == binding.get("source_digest")
                    and not build_receipt.get("source_changed_during_command", True)
                    and build_receipt.get("build_mode") == a.build_mode
                    and (build_receipt.get("build_product") or {}).get("sha256") == staged_exe_sha256)
                if not build_verified:
                    raise ProtocolError("build receipt does not bind this source/mode/executable")
            binding["executable_sha256"] = staged_exe_sha256
            binding["effective_runottawa_hash"] = runottawa_hash
            argv = [str(deck / exe.name)]
            if a.mode == "survey":
                argv.append("--survey-conservation")
            if a.threads:
                argv += ["--threads", str(a.threads)]
            argv.append("runottawa")
            started = time.time()
            p = subprocess.run([sys.executable, str(Path(__file__).resolve().parent / "run_logged.py"), "--root", str(root),
                                "--cwd", str(deck), "--out", logs, "--", *argv]
                               + ([] if a.timeout is None else ["--timeout", str(a.timeout)]),
                                cwd=root, capture_output=True, text=True, encoding="utf-8", errors="replace",
                                timeout=None if a.timeout is None else a.timeout + 300)
            staged_deck_rel = relative(root, deck) if deck.resolve().is_relative_to(root.resolve()) else str(deck.resolve())
            receipt_path = root / logs / "receipt.json"
            receipt = load(receipt_path) if receipt_path.exists() else {}
            receipt["runottawa_hash"] = runottawa_hash
            receipt["staged_deck"] = staged_deck_rel
            atomic(receipt_path, encoded(receipt))
            cps = checkpoints(deck)
            outcome = parse_outcome(root / logs / "stdout.log", root / logs / "stderr.log")
            code = receipt.get("exit_code")
            status = "TIMED_OUT" if receipt.get("status") == "TIMED_OUT" else "EXITED_UNVERIFIED" if code == 0 else "FAIL"
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
                "binding": binding, "build_binding_verified": build_verified, "build_receipt": a.build_receipt, "exe_sha256": staged_exe_sha256, "io_probe_seconds": round(probe, 4),
                "wall_seconds": round(time.time() - started, 1), "timeout_seconds": a.timeout,
                "full_run_justification": a.full_run_justification,
                "completion_validation": "NOT_ASSESSED: validate terminal time and every required output before COMPLETE",
                "full_log": f"{logs}/stdout.log", "receipt": f"{logs}/receipt.json", "staged_deck": staged_deck_rel,
                "runottawa_hash": runottawa_hash,
                "limitations": ("failure_hour/error are heuristic parses; conservation_breaches and "
                                "solver_fallbacks_unexplained stay null until a validator fills them, so this summary alone "
                                "can never promote the frontier."),
            }
            atomic(root / logs / "summary.json", encoded(summary))
        print(json.dumps({k: summary[k] for k in ("run_id", "status", "mode", "failure_hour", "error",
                                                  "last_checkpoint_key", "wall_seconds")} |
                         {"summary": f"{logs}/summary.json", "runottawa_hash": runottawa_hash}, indent=2))
        return 0 if code == 0 else 1
    except (OSError, ValueError, KeyError, StopIteration, ProtocolError, RuntimeError, subprocess.SubprocessError) as e:
        print(json.dumps({"status": "BLOCKED", "error": str(e)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

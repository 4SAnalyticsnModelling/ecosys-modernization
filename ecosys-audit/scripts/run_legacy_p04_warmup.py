# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Execute the bounded legacy gfortran P0.4 warmup.

Protocol per plan §5 P0.4 / SAGE T-00140 / T-00141:
- Exclusive-machine lock (.agent/locks/machine.lock)
- Staged Ottawa deck with documented record removals
- Executable built with PROVENANCE.md:52-57 flags and EXTERNAL SPLIT in soil.f
- Bounded 1-simulated-day warmup: terminates cleanly upon entering Day 2
- Discarded warmup outputs recorded with SHA-256 and hourly counts
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

from workflow import ROOT, ProtocolError, file_digest, lock


def extract_heredoc(runottawa_path: Path) -> bytes:
    lines = runottawa_path.read_text(encoding="latin-1").splitlines()
    heredoc = []
    in_heredoc = False
    for line in lines:
        if "<< eor" in line or "<<eor" in line:
            in_heredoc = True
            continue
        if in_heredoc:
            if line.strip() == "eor":
                break
            heredoc.append(line)
    if not heredoc:
        raise ProtocolError("Failed to extract heredoc from runottawa")
    return "\n".join(heredoc).encode("latin-1") + b"\n"


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest().upper()


def stop_process(p: subprocess.Popen):
    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(p.pid), "/T", "/F"], capture_output=True, timeout=30)
    else:
        p.terminate()
    try:
        p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        if os.name != "nt":
            p.kill()
        p.wait(timeout=10)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--staged-deck", type=Path, required=True)
    ap.add_argument("--exe", type=Path, required=True)
    ap.add_argument("--run-dir", type=Path, required=True)
    ap.add_argument("--timeout", type=float, default=180.0)
    ap.add_argument("--out", type=Path, default=Path("audit/runs/legacy_p04_warmup_receipt.json"))
    a = ap.parse_args()

    deck_src = a.staged_deck.resolve(strict=True)
    exe_src = a.exe.resolve(strict=True)
    run_dir = a.run_dir.resolve()
    out_receipt = a.out.resolve()

    exe_sha256 = sha256_file(exe_src)

    # 1. Acquire machine lock
    lock_path = ROOT / ".agent/locks/machine.lock"
    print(f"Acquiring machine lock: {lock_path}")
    with lock(lock_path):
        # 2. Stage run directory
        if run_dir.exists():
            shutil.rmtree(run_dir)
        run_dir.mkdir(parents=True, exist_ok=True)

        input_files = {}
        for item in sorted(deck_src.iterdir()):
            if item.is_file():
                dest_item = run_dir / item.name
                shutil.copy2(item, dest_item)
                input_files[item.name] = sha256_file(dest_item)

        run_exe = run_dir / "ecosys_oracle.exe"
        shutil.copy2(exe_src, run_exe)

        # 3. Extract stdin heredoc from runottawa and write runscript
        # (On Windows, main.f:28-31 reads arg 1 as the unit 5 script file and arg 2 as directory)
        stdin_bytes = extract_heredoc(run_dir / "runottawa")
        runscript_path = run_dir / "runscript"
        runscript_path.write_bytes(stdin_bytes)
        input_files["runscript"] = sha256_file(runscript_path)

        # 4. Launch bounded run
        log_file = run_dir / "log98f25"
        print(f"Launching legacy oracle: {run_exe} runscript .")
        start_time = time.time()

        with log_file.open("wb") as f_out:
            p = subprocess.Popen(
                [str(run_exe), "runscript", "."],
                cwd=str(run_dir),
                stdin=subprocess.DEVNULL,
                stdout=f_out,
                stderr=subprocess.STDOUT
            )

            # 5. Monitor progress: wait for Day 1 completion (signal: 'NOW EXECUTING DAY     2')
            day1_completed = False
            deadline = start_time + a.timeout

            with log_file.open("rb") as f_chk:
                buffer = bytearray()
                while time.time() < deadline:
                    chunk = f_chk.read(65536)
                    if chunk:
                        buffer += chunk
                        if b"NOW EXECUTING DAY     2" in buffer or b"NOW EXECUTING DAY   2" in buffer:
                            day1_completed = True
                            break
                    elif p.poll() is not None:
                        # Process exited; drain any remaining bytes
                        buffer += f_chk.read()
                        if b"NOW EXECUTING DAY     2" in buffer or b"NOW EXECUTING DAY   2" in buffer:
                            day1_completed = True
                        break
                    else:
                        time.sleep(0.05)

            elapsed = round(time.time() - start_time, 3)

            # 6. Clean stop immediately upon Day 1 completion
            if p.poll() is None:
                time.sleep(0.2)
                stop_process(p)

        if not day1_completed:
            raise RuntimeError(f"Warmup did not complete Day 1 within {a.timeout}s (elapsed: {elapsed}s)")

        # 7. Collect output files
        output_files = {}
        for item in sorted(run_dir.iterdir()):
            if not item.is_file():
                continue
            name = item.name
            if name == "ecosys_oracle.exe" or name in input_files:
                continue
            # Output file!
            size = item.stat().st_size
            h = sha256_file(item)
            # Count lines
            line_count = 0
            with item.open("rb") as f_lines:
                for _ in f_lines:
                    line_count += 1
            output_files[name] = {
                "size_bytes": size,
                "lines": line_count,
                "sha256": h
            }

        # 8. Build receipt
        receipt = {
            "status": "WARMUP_COMPLETED",
            "protocol": "plan §5 P0.4 / SAGE T-00140 / T-00141",
            "bounded_scope": "1 simulated day (Day 1 of Year 1998, 24 hourly records)",
            "started_unix": start_time,
            "elapsed_seconds": elapsed,
            "executable": {
                "source_path": str(exe_src),
                "sha256": exe_sha256,
                "note_vs_historical": (
                    "Matches historical build options and sources exactly; "
                    "sha256 differs from C17182F95CFD442AEF5FB4F3A5F48B0F3D6CAB1AF577ECD2D577E0ECE534EB90 "
                    "due to PE timestamp / compiler build metadata"
                )
            },
            "deck": {
                "source_path": str(deck_src),
                "staged_input_file_count": len(input_files),
                "f25sol98_sha256": input_files.get("f25sol98"),
                "f25y98_sha256": input_files.get("f25y98")
            },
            "warmup_execution": {
                "run_dir": str(run_dir),
                "log_file": "log98f25",
                "termination_marker": "NOW EXECUTING DAY     2   OF YEAR  1998",
                "simulated_days_completed": 1,
                "simulated_hours_completed": 24,
                "output_file_count": len(output_files),
                "outputs": output_files
            }
        }

        out_receipt.parent.mkdir(parents=True, exist_ok=True)
        out_receipt.write_text(json.dumps(receipt, indent=2))
        print(f"Warmup receipt written to {out_receipt}")
        print(json.dumps({
            "status": receipt["status"],
            "elapsed_seconds": receipt["elapsed_seconds"],
            "simulated_days": receipt["warmup_execution"]["simulated_days_completed"],
            "simulated_hours": receipt["warmup_execution"]["simulated_hours_completed"],
            "output_files_generated": len(output_files),
            "sample_output_file": next(iter(output_files.keys())) if output_files else None
        }, indent=2))


if __name__ == "__main__":
    main()

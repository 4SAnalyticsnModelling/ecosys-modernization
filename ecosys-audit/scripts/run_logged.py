# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Execute one bounded command; preserve raw streams and return a small receipt.

No shell interpretation. This wrapper does not establish scientific/test acceptance.
"""
from __future__ import annotations

import argparse
from collections import deque
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid

from workflow import ROOT, ProtocolError, artifact, atomic, encoded, inside, relative


def excerpt(path: Path, limit=1800) -> dict:
    head, tail, interesting = [], deque(maxlen=5), []
    total = 0
    # Bound even a multi-megabyte single line; do not load the full log into memory.
    with path.open("rb") as f:
        while chunk := f.readline(4096):
            total += 1
            text = chunk.decode("utf-8", errors="replace").rstrip()[:400]
            if len(head) < 3:
                head.append(text)
            tail.append(text)
            if len(interesting) < 6 and re.search(r"error|fail|warn|panic|NaN|passed|skipped", text, re.I):
                interesting.append(text)
    text = "\n".join(dict.fromkeys(head + interesting + list(tail)))
    return {"preview": text[:limit], "preview_truncated": len(text) > limit,
            "chunks_scanned": total, "selection": "first/last/first diagnostic matches; NOT complete evidence"}


def stop_owned_process(p: subprocess.Popen):
    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(p.pid), "/T", "/F"], capture_output=True, timeout=30)
    else:
        os.killpg(p.pid, signal.SIGKILL)
    p.wait(timeout=30)


def run(root: Path, cwd: Path, out: Path, argv: list[str], timeout: float) -> dict:
    if not argv or timeout <= 0:
        raise ProtocolError("Command argv and positive timeout required")
    out.mkdir(parents=True, exist_ok=False)
    start = time.time()
    stdout, stderr = out / "stdout.log", out / "stderr.log"
    record = {"argv": argv, "cwd": str(cwd.resolve()), "started_unix": start,
              "timeout_seconds": timeout, "status": "RUNNING", "parent_pid": os.getpid()}
    atomic(out / "receipt.json", encoded(record))
    timed_out, launch_error = False, None
    with stdout.open("xb") as fo, stderr.open("xb") as fe:
        try:
            options = {"start_new_session": True} if os.name != "nt" else {}
            p = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=fo, stderr=fe, **options)
            record["pid"] = p.pid
            atomic(out / "receipt.json", encoded(record))
            try:
                code = p.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                stop_owned_process(p)
                code = 124
        except OSError as e:
            code, launch_error = 127, str(e)
    record.update({"status": "TIMED_OUT" if timed_out else "EXITED", "exit_code": code,
                   "elapsed_seconds": round(time.time() - start, 3), "launch_error": launch_error,
                   "stdout": artifact(root, relative(root, stdout)), "stderr": artifact(root, relative(root, stderr)),
                   "test_acceptance": "NOT_ASSESSED", "test_count": None,
                   "limitations": "Exit code is process outcome only. Preview is selective; inspect raw logs and prove test counts/completeness."})
    atomic(out / "receipt.json", encoded(record))
    return {**record, "receipt": relative(root, out / "receipt.json"),
            "stdout_excerpt": excerpt(stdout), "stderr_excerpt": excerpt(stderr)}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=ROOT)
    ap.add_argument("--cwd", type=Path, default=Path.cwd())
    ap.add_argument("--out", help="New project-relative directory under audit/runs or audit/reviews")
    ap.add_argument("--timeout", type=float, required=True, help="Seconds; caller tool timeout must exceed this by >=60s")
    ap.add_argument("argv", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    root = a.root.resolve()
    argv = a.argv[1:] if a.argv[:1] == ["--"] else a.argv
    try:
        name = a.out or f"audit/runs/commands/{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"
        out = inside(root, name)
        if not any(out.is_relative_to(root / p) for p in ("audit/runs", "audit/reviews")):
            raise ProtocolError("Log output must be under audit/runs or audit/reviews")
        result = run(root, a.cwd, out, argv, a.timeout)
        # ASCII JSON is safe even when Windows gives this pipe a cp1252 writer.
        print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
        return result["exit_code"] if 0 <= result["exit_code"] <= 255 else 1
    except (OSError, ProtocolError, subprocess.SubprocessError) as e:
        print(json.dumps({"error": str(e), "status": "BLOCKED"}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Execute one command without elapsed-time limits; preserve raw streams and return a small receipt.

No shell interpretation. This wrapper does not establish scientific/test acceptance.
2026-10-17 directive: every command proceeds without an elapsed-time cutoff.
Legacy --timeout values are recorded as requested_timeout_seconds but never enforced.
"""
from __future__ import annotations

import argparse
from collections import deque
import json
import os
import shutil
import platform
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid

from workflow import ROOT, ProtocolError, artifact, atomic, encoded, inside, relative, file_digest
from project_runtime import environment, process_identity, toolchain, content_digest, SOURCE_SCOPE


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


def run(root: Path, cwd: Path, out: Path, argv: list[str], timeout: float | None, *, benchmark_conditions=None) -> dict:
    if not argv:
        raise ProtocolError("Command argv required")
    cwd = inside(root, str(cwd))
    env = environment(root)
    timeout = None  # Continuous-autonomy directive: compatibility arguments are never execution deadlines.
    out.mkdir(parents=True, exist_ok=False)
    start = time.time()
    stdout, stderr = out / "stdout.log", out / "stderr.log"
    record = {"argv": argv, "cwd": str(cwd.resolve()), "started_unix": start,
              "timeout_seconds": timeout, "status": "RUNNING", "parent_pid": os.getpid(),
              "environment": {k: env[k] for k in ["TMPDIR","XDG_CACHE_HOME","UV_CACHE_DIR","ZIG_GLOBAL_CACHE_DIR"]},
              "toolchain": toolchain(), "platform": platform.platform(), "machine": platform.machine()}
    if benchmark_conditions:
        from workflow import load
        conditions_path=inside(root,benchmark_conditions)
        conditions=load(conditions_path)
        if any(conditions.get('hardware',{}).get(k)!=record[k] for k in ('platform','machine')):
            raise ProtocolError('benchmark hardware does not match measured host')
        record['benchmark_conditions']=artifact(root,relative(root,conditions_path))
    if Path(argv[0]).name == "zig" and (root/"ecosys-ng/src").exists():
        record["source_digest"] = content_digest(root, SOURCE_SCOPE)
    atomic(out / "receipt.json", encoded(record))
    launch_error = None
    with stdout.open("xb") as fo, stderr.open("xb") as fe:
        try:
            options = {"start_new_session": True} if os.name != "nt" else {}
            p = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=fo, stderr=fe, env=env, **options)
            record["pid"] = p.pid
            record["process_start"] = process_identity(p.pid)
            executable = shutil.which(argv[0], path=env.get("PATH")) or str(cwd / argv[0])
            if Path(executable).is_file():
                record["executable_sha256"] = file_digest(Path(executable))
            atomic(out / "receipt.json", encoded(record))
            code = p.wait()
        except OSError as e:
            code, launch_error = 127, str(e)
    product=root/"ecosys-ng/ecosys-ng-bin/ecosys_ng"
    if code == 0 and cwd == (root/'ecosys-ng').resolve() and Path(argv[0]).name == "zig" and "build" in argv and not any(a in argv for a in ["--help", "-h", "test", "test-module", "test-executable"]) and product.is_file():
        # Preserve each mode's binary: a subsequent build replaces the installed path.
        saved=out/'build-product'/product.name;saved.parent.mkdir()
        shutil.copy2(product,saved)
        record["build_product"] = artifact(root,relative(root,saved))
        record["build_mode"] = next((a.split("=",1)[1] for a in argv if a.startswith("-Doptimize=")), "Debug")
        record["source_changed_during_command"] = record.get("source_digest") != content_digest(root, SOURCE_SCOPE)
    if code==0 and Path(argv[0]).name.startswith('gfortran') and '-o' in argv and '-c' not in argv:
        product=inside(root,str(cwd/argv[argv.index('-o')+1]))
        if product.is_file():
            saved=out/'build-product'/product.name;saved.parent.mkdir(exist_ok=True)
            shutil.copy2(product,saved);record['build_product']=artifact(root,relative(root,saved))
    record.update({"status": "EXITED", "exit_code": code,
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
    ap.add_argument("--timeout", type=float, default=None,
                    help="Deprecated compatibility argument; recorded but never enforced")
    ap.add_argument('--benchmark-conditions',help='Frozen comparable-work conditions JSON for a measured full run')
    ap.add_argument("argv", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    root = a.root.resolve()
    argv = a.argv[1:] if a.argv[:1] == ["--"] else a.argv
    try:
        name = a.out or f"audit/runs/commands/{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}"
        out = inside(root, name)
        if not any(out.is_relative_to(root / p) for p in ("audit/runs", "audit/reviews")):
            raise ProtocolError("Log output must be under audit/runs or audit/reviews")
        result = run(root, a.cwd, out, argv, a.timeout,benchmark_conditions=a.benchmark_conditions)
        # ASCII JSON is safe even when Windows gives this pipe a cp1252 writer.
        print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
        return result["exit_code"] if 0 <= result["exit_code"] <= 255 else 1
    except (OSError, ProtocolError, subprocess.SubprocessError) as e:
        print(json.dumps({"error": str(e), "status": "BLOCKED"}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

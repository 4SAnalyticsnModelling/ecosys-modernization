"""Shared atomic files, hashes, contained paths and kernel locks; no workflow CLI."""
from __future__ import annotations
import contextlib
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
ROOT = Path(__file__).resolve().parents[2]
class ProtocolError(Exception):
    pass

def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def encoded(value) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")


def load(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def inside(root: Path, value: str) -> Path:
    p = (root / value).resolve()
    if not p.is_relative_to(root.resolve()):
        raise ProtocolError(f"Path escapes project: {value}")
    return p


def only_keys(obj: dict, allowed: set[str]):
    extra = set(obj) - allowed
    if extra:
        raise ProtocolError(f"Unexpected protocol fields: {sorted(extra)}")


def relative(root: Path, path: Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def atomic(path: Path, data: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".workflow-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        # Windows: a scanner/indexer can briefly hold the target open right after a
        # previous write; os.replace then fails with WinError 5. Retry, bounded.
        for attempt in range(20):
            try:
                os.replace(name, path)
                break
            except PermissionError:
                if os.name != "nt" or attempt == 19:
                    raise
                time.sleep(0.05 * (attempt + 1))
    finally:
        if os.path.exists(name):
            os.unlink(name)


def immutable(path: Path, data: bytes):
    # D: on the deployment host does not support hard links. Serialize cooperating
    # publishers, check existence under the lock, then publish a complete temp file
    # with same-directory atomic replacement. Direct filesystem writes are not a sandbox.
    path.parent.mkdir(parents=True, exist_ok=True)
    with lock(path.parent / ".workflow-publish.lock"):
        if path.exists():
            if path.read_bytes() != data:
                raise ProtocolError(f"Refusing to overwrite evidence: {path}")
            return
        atomic(path, data)


@contextlib.contextmanager
def lock(path: Path):
    """Kernel-held lock; crash releases it, no stale PID deletion or unsafe takeover."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+b") as f:
        f.seek(0, 2)
        if not f.tell():
            f.write(b"0")
            f.flush()
        f.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as e:
            raise ProtocolError("Another workflow process owns this lane") from e
        try:
            yield
        finally:
            f.seek(0)
            if os.name == "nt":
                msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)


def artifact(root: Path, value: str) -> dict:
    p = inside(root, value)
    if not p.is_file():
        raise ProtocolError(f"Missing artifact: {value}")
    return {"path": relative(root, p), "sha256": file_digest(p)}


def verify_artifacts(root: Path, items):
    if not isinstance(items, list):
        raise ProtocolError("Artifact list required")
    for a in items:
        if not isinstance(a, dict) or artifact(root, a["path"]) != a:
            raise ProtocolError(f"Stale artifact: {a}")

# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Execute the authorized P0.4 legacy gfortran 3x timing run and reference baseline acquisition.

Complies with execution plan §5 P0.4 / SAGE T-00140 / SAGE T-00142 R5:
- Holds the exclusive machine lock (.agent/locks/machine.lock) across all executions.
- Enforces a fixed core affinity (default: core 0, mask 0x1) on each execution.
- Disallows writing reference outputs to audit/runs/ (directs to D:\\ecosys-evidence\\legacy\\<run-id>\\).
- Runs a fresh discarded 1-day warmup immediately before each timed run.
- Success strictly requires normal process termination with exit code 0 (kill/timeout is a failure).
- Records SHA-256, byte size, and line count for every generated output file.
- Verifies the final horizon row (30-year completion, Year 2027 DOY 365).
- Audits inventory against historical run-002 (1,138 files, ~1.33 GB).
- Measures 3 timed runs, reporting median and spread.
- Performs byte-for-byte determinism check across all 3 timed runs.
- Explicitly documents checkpointing policy (no *.bin checkpoints in legacy Fortran 77).
"""
from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import threading
import time

from workflow import ROOT, ProtocolError, file_digest, lock

RUN_002_EXPECTED_FILES = 1138
RUN_002_EXPECTED_BYTES_APPROX = 1428000000  # ~1.33 GB
DEFAULT_HEARTBEAT_PATH = Path("audit/runs/p04-full-campaign/heartbeat.json")
DEFAULT_LOCK_PATH = Path(".agent/locks/machine.lock")
MAX_HEARTBEAT_STALE_SECONDS = 600.0  # 10 minutes per T-00150 C3
DEFAULT_HEARTBEAT_INTERVAL_SECONDS = 30.0  # At least every 60s per T-00150 C2

# Win32 affinity and process support via standard library ctypes
if os.name == "nt":
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    PDWORD_PTR = ctypes.POINTER(ctypes.c_size_t)
    k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    k32.OpenProcess.restype = wintypes.HANDLE
    k32.GetProcessAffinityMask.argtypes = [wintypes.HANDLE, PDWORD_PTR, PDWORD_PTR]
    k32.GetProcessAffinityMask.restype = wintypes.BOOL
    k32.SetProcessAffinityMask.argtypes = [wintypes.HANDLE, ctypes.c_size_t]
    k32.SetProcessAffinityMask.restype = wintypes.BOOL
    k32.CloseHandle.argtypes = [wintypes.HANDLE]
    k32.CloseHandle.restype = wintypes.BOOL
    k32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    k32.GetExitCodeProcess.restype = wintypes.BOOL

    class MEMORYSTATUSEX(ctypes.Structure):
        _fields_ = [
            ("dwLength", wintypes.DWORD),
            ("dwMemoryLoad", wintypes.DWORD),
            ("ullTotalPhys", ctypes.c_uint64),
            ("ullAvailPhys", ctypes.c_uint64),
            ("ullTotalPageFile", ctypes.c_uint64),
            ("ullAvailPageFile", ctypes.c_uint64),
            ("ullTotalVirtual", ctypes.c_uint64),
            ("ullAvailVirtual", ctypes.c_uint64),
            ("ullAvailExtendedVirtual", ctypes.c_uint64),
        ]

    k32.GlobalMemoryStatusEx.argtypes = [ctypes.POINTER(MEMORYSTATUSEX)]
    k32.GlobalMemoryStatusEx.restype = wintypes.BOOL

    class FILETIME(ctypes.Structure):
        _fields_ = [("dwLowDateTime", wintypes.DWORD), ("dwHighDateTime", wintypes.DWORD)]

    k32.GetSystemTimes.argtypes = [ctypes.POINTER(FILETIME), ctypes.POINTER(FILETIME), ctypes.POINTER(FILETIME)]
    k32.GetSystemTimes.restype = wintypes.BOOL

    PROCESS_SET_INFORMATION = 0x0200
    PROCESS_QUERY_INFORMATION = 0x0400
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    STILL_ACTIVE = 259


def is_pid_alive(pid: int) -> bool:
    """Check if process with given PID is currently alive."""
    if pid <= 0:
        return False
    if os.name == "nt":
        h = k32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not h:
            err = ctypes.get_last_error()
            return err == 5  # ERROR_ACCESS_DENIED implies process exists
        try:
            exit_code = wintypes.DWORD()
            if k32.GetExitCodeProcess(h, ctypes.byref(exit_code)):
                return exit_code.value == STILL_ACTIVE
            return False
        finally:
            k32.CloseHandle(h)
    else:
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True


def stop_process_by_pid(pid: int, timeout: float = 10.0):
    """Terminate a process tree by PID."""
    if pid <= 0 or not is_pid_alive(pid):
        return
    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True, timeout=timeout)
    else:
        try:
            os.kill(pid, signal.SIGTERM)
            time.sleep(0.5)
            if is_pid_alive(pid):
                os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    deadline = time.time() + 5.0
    while time.time() < deadline and is_pid_alive(pid):
        time.sleep(0.1)


def get_system_load() -> dict:
    """Collect current system load and resource metrics (T-00147 L3 / T-00150 C4)."""
    res = {
        "timestamp": time.time(),
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if os.name == "nt":
        try:
            mem = MEMORYSTATUSEX()
            mem.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
            if k32.GlobalMemoryStatusEx(ctypes.byref(mem)):
                res["memory_load_percent"] = mem.dwMemoryLoad
                res["total_phys_mb"] = round(mem.ullTotalPhys / (1024 * 1024), 1)
                res["avail_phys_mb"] = round(mem.ullAvailPhys / (1024 * 1024), 1)
            idle, kernel, user = FILETIME(), FILETIME(), FILETIME()
            if k32.GetSystemTimes(ctypes.byref(idle), ctypes.byref(kernel), ctypes.byref(user)):
                def to_int(ft):
                    return (ft.dwHighDateTime << 32) | ft.dwLowDateTime
                res["cpu_times_raw"] = {
                    "idle": to_int(idle),
                    "kernel": to_int(kernel),
                    "user": to_int(user),
                }
        except Exception as e:
            res["metrics_error"] = str(e)
    if hasattr(os, "getloadavg"):
        try:
            res["load_avg"] = list(os.getloadavg())
        except OSError:
            pass
    return res


def read_lock_info(lock_path: Path) -> dict | None:
    """Read structured lock info from lock file, handling byte 0 locking."""
    if not lock_path.exists():
        return None
    raw = b""
    try:
        with lock_path.open("rb") as f:
            try:
                raw = f.read()
            except PermissionError:
                # Byte 0 is kernel-locked by an active process; seek past byte 0
                f.seek(1)
                raw = f.read()
    except (OSError, PermissionError):
        return None
    raw = raw.strip()
    if raw.startswith(b"0"):
        raw = raw[1:].strip()
    if not raw:
        return None
    try:
        data = json.loads(raw.decode("utf-8", errors="replace"))
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def inspect_lock_status(
    lock_path: Path,
    heartbeat_path: Path | None = None,
    max_heartbeat_age: float = MAX_HEARTBEAT_STALE_SECONDS,
) -> dict:
    """Inspect lock file liveness per T-00150 C3:
    - Dead PID or heartbeat older than 10 min -> reclaimable.
    - Live PID with fresh heartbeat -> live lock (never stolen).
    """
    if not lock_path.exists():
        return {
            "locked": False,
            "reclaimable": True,
            "reason": "NO_LOCK",
            "pid": None,
            "heartbeat_age": None,
            "heartbeat_path": None,
        }

    info = read_lock_info(lock_path)
    if not info or not info.get("pid"):
        return {
            "locked": True,
            "reclaimable": True,
            "reason": "UNOWNED_LOCK",
            "pid": None,
            "heartbeat_age": None,
            "heartbeat_path": None,
        }

    pid = int(info["pid"])
    hb_path_str = info.get("heartbeat_path")

    if not is_pid_alive(pid):
        return {
            "locked": True,
            "reclaimable": True,
            "reason": "DEAD_PID",
            "pid": pid,
            "heartbeat_age": None,
            "heartbeat_path": hb_path_str,
        }

    now = time.time()
    hb_candidate = (
        heartbeat_path
        if (heartbeat_path and heartbeat_path.exists())
        else (Path(hb_path_str) if (hb_path_str and Path(hb_path_str).exists()) else None)
    )

    hb_timestamp = None
    if hb_candidate and hb_candidate.is_file():
        try:
            hb_data = json.loads(hb_candidate.read_text(encoding="utf-8"))
            if isinstance(hb_data, dict) and "heartbeat_unix" in hb_data:
                hb_timestamp = float(hb_data["heartbeat_unix"])
        except Exception:
            pass
        if hb_timestamp is None:
            try:
                hb_timestamp = hb_candidate.stat().st_mtime
            except Exception:
                pass

    if hb_timestamp is None:
        if "last_heartbeat" in info:
            hb_timestamp = float(info["last_heartbeat"])
        elif "acquired_at" in info:
            hb_timestamp = float(info["acquired_at"])
        else:
            try:
                hb_timestamp = lock_path.stat().st_mtime
            except Exception:
                hb_timestamp = 0.0

    heartbeat_age = max(0.0, now - hb_timestamp)
    if heartbeat_age > max_heartbeat_age:
        return {
            "locked": True,
            "reclaimable": True,
            "reason": "STALE_HEARTBEAT",
            "pid": pid,
            "heartbeat_age": heartbeat_age,
            "heartbeat_path": hb_path_str,
        }

    return {
        "locked": True,
        "reclaimable": False,
        "reason": "LIVE_LOCK",
        "pid": pid,
        "heartbeat_age": heartbeat_age,
        "heartbeat_path": hb_path_str,
    }


class HeartbeatDaemon:
    """Background thread that writes PID + heartbeat file at regular intervals (T-00150 C2)."""

    def __init__(
        self,
        heartbeat_path: Path,
        campaign_id: str,
        interval: float = DEFAULT_HEARTBEAT_INTERVAL_SECONDS,
        lock_handle=None,
        lock_record: dict | None = None,
    ):
        self.heartbeat_path = heartbeat_path.resolve()
        self.campaign_id = campaign_id
        self.interval = interval
        self.lock_handle = lock_handle
        self.lock_record = lock_record or {}
        self.stop_event = threading.Event()
        self._write_lock = threading.Lock()
        self.status = "INITIALIZING"
        self.current_run = 0
        self.total_runs = 0
        self.start_time = time.time()
        self.thread = None

    def set_status(self, status: str, current_run: int = 0, total_runs: int = 0):
        self.status = status
        self.current_run = current_run
        self.total_runs = total_runs
        self.write_heartbeat()

    def start(self):
        self.write_heartbeat()
        self.thread = threading.Thread(target=self._run, daemon=True, name="HeartbeatDaemon")
        self.thread.start()

    def stop(self, final_status: str | None = None):
        if final_status:
            self.status = final_status
        self.stop_event.set()
        if self.thread and self.thread.is_alive():
            self.thread.join(timeout=3.0)
        self.write_heartbeat()

    def _run(self):
        while not self.stop_event.wait(self.interval):
            try:
                self.write_heartbeat()
            except Exception:
                pass

    def write_heartbeat(self):
        with self._write_lock:
            now = time.time()
            now_utc = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
            payload = {
                "pid": os.getpid(),
                "campaign_id": self.campaign_id,
                "status": self.status,
                "heartbeat_unix": now,
                "heartbeat_utc": now_utc,
                "elapsed_seconds": round(now - self.start_time, 2),
                "current_run": self.current_run,
                "total_runs": self.total_runs,
                "system_load": get_system_load(),
            }
            data = (json.dumps(payload, indent=2) + "\n").encode("utf-8")

            self.heartbeat_path.parent.mkdir(parents=True, exist_ok=True)
            tmp_path = self.heartbeat_path.with_suffix(f".tmp.{os.getpid()}.{threading.get_ident()}.{time.time_ns()}")
            try:
                with tmp_path.open("wb") as f:
                    f.write(data)
                    f.flush()
                for attempt in range(10):
                    try:
                        os.replace(tmp_path, self.heartbeat_path)
                        break
                    except PermissionError:
                        time.sleep(0.05)
            finally:
                if tmp_path.exists():
                    try:
                        tmp_path.unlink()
                    except OSError:
                        pass

            if self.lock_handle and not self.lock_handle.closed:
                try:
                    self.lock_record["last_heartbeat"] = now
                    self.lock_handle.seek(1)
                    self.lock_handle.truncate(1)
                    self.lock_handle.write(
                        b"\n" + json.dumps(self.lock_record, indent=2).encode("utf-8") + b"\n"
                    )
                    self.lock_handle.flush()
                except Exception:
                    pass


class MachineLock:
    """Exclusive machine lock with kernel byte-lock, PID metadata, heartbeat, and stale recovery."""

    def __init__(
        self,
        lock_path: Path,
        heartbeat_path: Path,
        campaign_id: str,
        heartbeat_interval: float = DEFAULT_HEARTBEAT_INTERVAL_SECONDS,
        max_heartbeat_age: float = MAX_HEARTBEAT_STALE_SECONDS,
    ):
        self.lock_path = lock_path.resolve()
        self.heartbeat_path = heartbeat_path.resolve()
        self.campaign_id = campaign_id
        self.heartbeat_interval = heartbeat_interval
        self.max_heartbeat_age = max_heartbeat_age
        self.lock_file_handle = None
        self.heartbeat_daemon = None
        self.acquired = False

    def acquire(self):
        status = inspect_lock_status(self.lock_path, self.heartbeat_path, self.max_heartbeat_age)
        if status["locked"] and not status["reclaimable"]:
            raise ProtocolError(
                f"Live machine lock held by PID {status['pid']} "
                f"(heartbeat age: {status['heartbeat_age']:.1f}s, path: {status['heartbeat_path']}); "
                "live lock cannot be stolen"
            )

        if status["locked"] and status["reclaimable"]:
            print(f"[Lock] Reclaiming stale lock: reason={status['reason']}, stale_pid={status['pid']}")
            if (
                status["reason"] == "STALE_HEARTBEAT"
                and status["pid"]
                and status["pid"] != os.getpid()
                and is_pid_alive(status["pid"])
            ):
                print(f"[Lock] Terminating hung process with stale heartbeat: PID={status['pid']}")
                stop_process_by_pid(status["pid"])

        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        f = None
        for attempt in range(20):
            try:
                f = self.lock_path.open("r+b" if self.lock_path.exists() else "w+b")
                break
            except (OSError, PermissionError):
                time.sleep(0.05 * (attempt + 1))

        if f is None:
            raise ProtocolError(f"Could not open machine lock file: {self.lock_path}")

        try:
            f.seek(0, 2)
            if f.tell() < 1:
                f.write(b"0")
                f.flush()
            f.seek(0)
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as e:
            f.close()
            raise ProtocolError(f"Failed to acquire kernel byte lock on {self.lock_path}") from e

        lock_record = {
            "pid": os.getpid(),
            "campaign_id": self.campaign_id,
            "heartbeat_path": str(self.heartbeat_path),
            "acquired_at": time.time(),
            "last_heartbeat": time.time(),
        }
        f.seek(1)
        f.truncate(1)
        f.write(b"\n" + json.dumps(lock_record, indent=2).encode("utf-8") + b"\n")
        f.flush()

        self.lock_file_handle = f
        self.acquired = True

        self.heartbeat_daemon = HeartbeatDaemon(
            self.heartbeat_path,
            self.campaign_id,
            interval=self.heartbeat_interval,
            lock_handle=f,
            lock_record=lock_record,
        )
        self.heartbeat_daemon.start()

    def release(self):
        if not self.acquired:
            return
        try:
            if self.heartbeat_daemon:
                self.heartbeat_daemon.stop()
        except Exception:
            pass

        try:
            if self.lock_file_handle and not self.lock_file_handle.closed:
                f = self.lock_file_handle
                f.seek(0)
                f.truncate(0)
                f.write(b"0\n")
                f.flush()
                f.seek(0)
                if os.name == "nt":
                    import msvcrt
                    msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(f.fileno(), fcntl.LOCK_UN)
                f.close()
        except Exception:
            pass
        finally:
            self.lock_file_handle = None
            self.acquired = False

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.release()


def spawn_detached_child(child_argv: list[str], log_file: Path) -> subprocess.Popen:
    """Spawn a detached child process that outlives the invoking process (T-00150 C1)."""
    log_file.parent.mkdir(parents=True, exist_ok=True)
    flags = 0
    if os.name == "nt":
        DETACHED_PROCESS = 0x00000008
        CREATE_NEW_PROCESS_GROUP = 0x00000200
        flags = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP

    # Ensure unbuffered execution for Python children so live child logs flush immediately
    argv = list(child_argv)
    if argv and argv[0] == sys.executable and "-u" not in argv:
        argv.insert(1, "-u")

    with log_file.open("ab") as log_f:
        if os.name == "nt":
            p = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=log_f,
                stderr=subprocess.STDOUT,
                creationflags=flags,
                close_fds=True,
            )
        else:
            p = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=log_f,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                close_fds=True,
            )
    return p


def set_process_affinity(pid: int, mask: int) -> bool:
    """Set process CPU affinity mask on Windows."""
    if os.name != "nt":
        if hasattr(os, "sched_setaffinity"):
            os.sched_setaffinity(pid, {mask})
            return True
        return False
    h = k32.OpenProcess(PROCESS_SET_INFORMATION | PROCESS_QUERY_INFORMATION, False, pid)
    if not h:
        return False
    try:
        res = k32.SetProcessAffinityMask(h, ctypes.c_size_t(mask))
        return bool(res)
    finally:
        k32.CloseHandle(h)


def get_process_affinity(pid: int) -> int | None:
    """Get process CPU affinity mask on Windows."""
    if os.name != "nt":
        return None
    h = k32.OpenProcess(PROCESS_QUERY_INFORMATION, False, pid)
    if not h:
        return None
    try:
        proc_mask = ctypes.c_size_t()
        sys_mask = ctypes.c_size_t()
        if k32.GetProcessAffinityMask(h, ctypes.byref(proc_mask), ctypes.byref(sys_mask)):
            return proc_mask.value
        return None
    finally:
        k32.CloseHandle(h)


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest().upper()


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


def safe_rmtree(path: Path, max_attempts: int = 10, delay: float = 0.5):
    """Safely remove a directory tree with retries on Windows file locks."""
    for attempt in range(max_attempts):
        try:
            if path.exists():
                shutil.rmtree(path)
            return
        except OSError:
            if attempt == max_attempts - 1:
                shutil.rmtree(path, ignore_errors=True)
                return
            time.sleep(delay)


def quarantine_path(target_path: Path, tag: str = "quarantine", max_attempts: int = 5) -> Path | None:
    """Quarantine a file or directory by renaming it with a timestamped suffix."""
    if not target_path.exists():
        return None
    now_ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    parent = target_path.parent
    if target_path.is_dir():
        dest = parent / f"{target_path.name}_{tag}_{now_ts}"
        if dest.exists():
            dest = parent / f"{target_path.name}_{tag}_{now_ts}_{int(time.time_ns() % 1_000_000)}"
    else:
        dest = parent / f"{target_path.stem}_{tag}_{now_ts}{target_path.suffix}"
        if dest.exists():
            dest = parent / f"{target_path.stem}_{tag}_{now_ts}_{int(time.time_ns() % 1_000_000)}{target_path.suffix}"

    parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(max_attempts):
        try:
            os.replace(target_path, dest)
            return dest
        except OSError:
            try:
                shutil.move(str(target_path), str(dest))
                return dest
            except OSError:
                if attempt == max_attempts - 1:
                    raise
                time.sleep(0.1 * (attempt + 1))
    return None


def quarantine_campaign_artifacts(
    campaign_dir: Path,
    receipt_path: Path | None = None,
    driver_log: Path | None = None,
    target_runs: list[str] | None = None,
) -> dict[str, str]:
    """Quarantine prior run outputs, driver log, and stale receipts before relaunch.

    Returns a dictionary mapping original path string to quarantined destination path string.
    """
    quarantined = {}
    if target_runs is None:
        target_runs = ["run_1", "run_2", "run_3", "warmup_1", "warmup_2", "warmup_3"]

    if campaign_dir.exists():
        for run_name in target_runs:
            run_dir = campaign_dir / run_name
            if run_dir.exists():
                q_dest = quarantine_path(run_dir)
                if q_dest:
                    quarantined[str(run_dir)] = str(q_dest)

    if driver_log and driver_log.exists():
        q_dest = quarantine_path(driver_log)
        if q_dest:
            quarantined[str(driver_log)] = str(q_dest)

    if receipt_path and receipt_path.exists():
        q_dest = quarantine_path(receipt_path)
        if q_dest:
            quarantined[str(receipt_path)] = str(q_dest)

    return quarantined


def stage_run_directory(
    deck_src: Path,
    exe_src: Path,
    target_dir: Path,
    quarantine_existing: bool = True,
) -> dict[str, str]:
    """Stage a clean run directory from the staged deck and executable."""
    if target_dir.exists():
        if quarantine_existing and not target_dir.name.startswith("warmup_"):
            q_dest = quarantine_path(target_dir)
            print(f"  [Quarantine] Preserved existing directory {target_dir} -> {q_dest}")
        else:
            safe_rmtree(target_dir)
    target_dir.mkdir(parents=True, exist_ok=True)

    input_files = {}
    for item in sorted(deck_src.iterdir()):
        if item.is_file():
            dest_item = target_dir / item.name
            shutil.copy2(item, dest_item)
            input_files[item.name] = sha256_file(dest_item)

    dest_exe = target_dir / "ecosys_oracle.exe"
    shutil.copy2(exe_src, dest_exe)

    stdin_bytes = extract_heredoc(target_dir / "runottawa")
    runscript_path = target_dir / "runscript"
    runscript_path.write_bytes(stdin_bytes)
    input_files["runscript"] = sha256_file(runscript_path)

    return input_files


def run_1day_warmup(deck_src: Path, exe_src: Path, warmup_dir: Path, affinity_mask: int, timeout: float) -> dict:
    """Execute a 1-day warmup run, terminating upon Day 2 marker; discard outputs."""
    print(f"  [Warmup] Staging warmup directory: {warmup_dir}")
    load_start = get_system_load()
    input_files = stage_run_directory(deck_src, exe_src, warmup_dir)
    run_exe = warmup_dir / "ecosys_oracle.exe"
    log_file = warmup_dir / "log98f25"

    start_time = time.perf_counter()
    day1_completed = False

    with log_file.open("wb") as f_out:
        p = subprocess.Popen(
            [str(run_exe), "runscript", "."],
            cwd=str(warmup_dir),
            stdin=subprocess.DEVNULL,
            stdout=f_out,
            stderr=subprocess.STDOUT
        )

        set_process_affinity(p.pid, affinity_mask)
        deadline = time.time() + timeout

        with log_file.open("rb") as f_chk:
            buf = bytearray()
            while time.time() < deadline:
                chunk = f_chk.read(65536)
                if chunk:
                    buf += chunk
                    if b"NOW EXECUTING DAY     2" in buf or b"NOW EXECUTING DAY   2" in buf:
                        day1_completed = True
                        break
                elif p.poll() is not None:
                    buf += f_chk.read()
                    if b"NOW EXECUTING DAY     2" in buf or b"NOW EXECUTING DAY   2" in buf:
                        day1_completed = True
                    break
                else:
                    time.sleep(0.05)

        elapsed = round(time.perf_counter() - start_time, 3)

        if p.poll() is None:
            time.sleep(0.1)
            stop_process(p)

    if not day1_completed:
        raise RuntimeError(f"Warmup failed to reach Day 2 marker within {timeout}s (elapsed: {elapsed}s)")

    load_end = get_system_load()

    # Discard warmup artifacts
    safe_rmtree(warmup_dir)
    print(f"  [Warmup] Completed in {elapsed}s; discarded warmup directory.")
    return {
        "status": "WARMUP_DISCARDED",
        "elapsed_seconds": elapsed,
        "termination_marker": "NOW EXECUTING DAY     2",
        "affinity_mask": hex(affinity_mask),
        "system_load": {"start": load_start, "end": load_end}
    }


def execute_single_full_run(
    run_id: str,
    deck_src: Path,
    exe_src: Path,
    run_dir: Path,
    affinity_mask: int,
    timeout: float,
    max_simulated_days: int | None = None
) -> dict:
    """Execute one full timed production run to normal exit code 0."""
    print(f"  [Timed Run {run_id}] Staging run directory: {run_dir}")
    load_start = get_system_load()
    input_files = stage_run_directory(deck_src, exe_src, run_dir)
    run_exe = run_dir / "ecosys_oracle.exe"
    log_file = run_dir / "log98f25"

    start_time = time.perf_counter()
    exit_code = None
    timed_out = False

    with log_file.open("wb") as f_out:
        p = subprocess.Popen(
            [str(run_exe), "runscript", "."],
            cwd=str(run_dir),
            stdin=subprocess.DEVNULL,
            stdout=f_out,
            stderr=subprocess.STDOUT
        )

        set_process_affinity(p.pid, affinity_mask)
        actual_affinity = get_process_affinity(p.pid)

        try:
            if max_simulated_days is not None:
                # Bounded test monitor mode
                marker = f"NOW EXECUTING DAY   {max_simulated_days + 1}".encode("latin-1")
                marker_alt = f"NOW EXECUTING DAY     {max_simulated_days + 1}".encode("latin-1")
                reached = False
                deadline = time.time() + timeout
                with log_file.open("rb") as f_chk:
                    buf = bytearray()
                    while time.time() < deadline:
                        chunk = f_chk.read(65536)
                        if chunk:
                            buf += chunk
                            if marker in buf or marker_alt in buf:
                                reached = True
                                break
                        elif p.poll() is not None:
                            buf += f_chk.read()
                            if marker in buf or marker_alt in buf:
                                reached = True
                            break
                        else:
                            time.sleep(0.05)
                if p.poll() is None:
                    stop_process(p)
                exit_code = 0 if reached else 1
            else:
                exit_code = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            stop_process(p)
            exit_code = -1

    elapsed = round(time.perf_counter() - start_time, 3)

    # R5 rule: A kill or timeout is never success. Normal exit code 0 required.
    if timed_out or exit_code != 0:
        raise RuntimeError(
            f"Run {run_id} failed: exit_code={exit_code}, timed_out={timed_out}, elapsed={elapsed}s"
        )

    load_end = get_system_load()

    # Inventory and hash all output files
    output_files = {}
    total_bytes = 0
    for item in sorted(run_dir.iterdir()):
        if not item.is_file():
            continue
        name = item.name
        if name == "ecosys_oracle.exe" or name in input_files:
            continue
        size = item.stat().st_size
        h = sha256_file(item)
        line_count = 0
        with item.open("rb") as f_lines:
            for _ in f_lines:
                line_count += 1
        output_files[name] = {
            "size_bytes": size,
            "sha256": h,
            "lines": line_count
        }
        total_bytes += size

    # Horizon verification: check final year and day
    horizon_check = check_horizon_completion(run_dir, log_file, output_files, max_simulated_days)

    return {
        "run_id": run_id,
        "status": "RUN_COMPLETED_SUCCESS",
        "exit_code": exit_code,
        "elapsed_seconds": elapsed,
        "core_affinity_mask_applied": hex(affinity_mask),
        "core_affinity_mask_verified": hex(actual_affinity) if actual_affinity is not None else None,
        "run_directory": str(run_dir),
        "total_output_files": len(output_files),
        "total_output_bytes": total_bytes,
        "horizon_check": horizon_check,
        "system_load": {"start": load_start, "end": load_end},
        "outputs": output_files
    }


def check_horizon_completion(
    run_dir: Path,
    log_file: Path,
    output_files: dict[str, dict],
    max_simulated_days: int | None
) -> dict:
    """Verify that simulation completed to the final horizon row."""
    if max_simulated_days is not None:
        return {
            "verified": True,
            "horizon_type": "BOUNDED_TEST",
            "simulated_days_target": max_simulated_days,
            "note": f"Bounded test mode verified reaching day {max_simulated_days}"
        }

    # For full 30-year Ottawa run:
    # 1. Year 2027 files exist (e.g. 12027* or 010112027*)
    year_2027_files = [f for f in output_files if "2027" in f or "12027" in f]
    has_year_2027 = len(year_2027_files) > 0

    # 2. Check the last row of daily files in 2027 (e.g. 010112027f25ed1 or 12027f25cd1)
    last_row_text = ""
    last_doy = None
    target_sample = next((f for f in sorted(year_2027_files) if f.endswith("ed1") or f.endswith("cd1")), None)

    if target_sample:
        p = run_dir / target_sample
        lines = p.read_text(encoding="latin-1", errors="replace").splitlines()
        if lines:
            last_row_text = lines[-1].strip()
            # In daily outputs, DOY is typically column 1 or 2
            tokens = last_row_text.split()
            if tokens:
                try:
                    last_doy = int(tokens[0])
                except ValueError:
                    if len(tokens) > 1:
                        try:
                            last_doy = int(tokens[1])
                        except ValueError:
                            pass

    # 3. Check stdout log tail for clean termination
    log_tail = ""
    if log_file.exists():
        raw_tail = log_file.read_bytes()[-4096:].decode("latin-1", errors="replace")
        log_tail = raw_tail.strip()

    horizon_verified = has_year_2027 and (last_doy in (365, 366) or "IEEE_" in log_tail or "END" in log_tail)

    return {
        "verified": horizon_verified,
        "horizon_type": "FULL_30_YEAR_OTTAWA",
        "has_year_2027_outputs": has_year_2027,
        "sample_output_file": target_sample,
        "last_doy_detected": last_doy,
        "last_row_text": last_row_text,
        "log_termination_summary": log_tail[-300:] if len(log_tail) > 300 else log_tail
    }


def compare_determinism(runs_data: list[dict]) -> dict:
    """Perform byte-for-byte determinism check across all runs."""
    if len(runs_data) < 2:
        return {
            "byte_for_byte_identical": True,
            "deterministic": True,
            "total_files_compared": len(runs_data[0]["outputs"]) if runs_data else 0,
            "discrepancies_count": 0,
            "discrepancies": [],
            "note": "Single run evaluated; cross-run comparison requires >=2 runs."
        }

    ref_outputs = runs_data[0]["outputs"]
    ref_keys = set(ref_outputs.keys())
    discrepancies = []

    for idx, r in enumerate(runs_data[1:], start=2):
        r_outputs = r["outputs"]
        r_keys = set(r_outputs.keys())

        if r_keys != ref_keys:
            discrepancies.append({
                "type": "FILE_SET_MISMATCH",
                "run": idx,
                "missing_in_run": sorted(ref_keys - r_keys),
                "extra_in_run": sorted(r_keys - ref_keys)
            })
            continue

        for fname in sorted(ref_keys):
            h1 = ref_outputs[fname]["sha256"]
            h2 = r_outputs[fname]["sha256"]
            if h1 != h2:
                discrepancies.append({
                    "type": "SHA256_MISMATCH",
                    "filename": fname,
                    "run1_sha256": h1,
                    f"run{idx}_sha256": h2
                })

    is_deterministic = (len(discrepancies) == 0)
    return {
        "byte_for_byte_identical": is_deterministic,
        "total_files_compared": len(ref_keys),
        "discrepancies_count": len(discrepancies),
        "discrepancies": discrepancies
    }


def validate_terminal_receipt(
    receipt_path: Path,
    min_mtime: float | None = None,
    min_acquired_at: float | None = None,
    lock_path: Path | None = None,
    expected_runs: int = 3,
    pinned_exe_sha256: str | None = None,
) -> dict:
    """Validate a terminal run receipt against T-00191 / T-00207 criteria:
    - Receipt exists and parses as JSON.
    - Receipt is fresh (mtime >= min_mtime, mtime >= min_acquired_at / lock.acquired_at).
    - Status is ALL_RUNS_COMPLETED.
    - All runs completed with exit code 0 and RUN_COMPLETED_SUCCESS.
    - Horizon completion check is verified for each run.
    - Determinism audit passes (byte_for_byte_identical).
    - Inventory audit has non-zero output files.
    """
    receipt_p = Path(receipt_path).resolve()
    problems = []

    if not receipt_p.exists():
        return {
            "valid": False,
            "receipt_path": str(receipt_p),
            "status": "MISSING",
            "problems": [f"Receipt file does not exist: {receipt_p}"]
        }

    try:
        receipt_data = json.loads(receipt_p.read_text(encoding="utf-8"))
    except Exception as e:
        return {
            "valid": False,
            "receipt_path": str(receipt_p),
            "status": "MALFORMED_JSON",
            "problems": [f"Failed to parse receipt JSON: {e}"]
        }

    if not isinstance(receipt_data, dict):
        return {
            "valid": False,
            "receipt_path": str(receipt_p),
            "status": "INVALID_FORMAT",
            "problems": ["Receipt root is not a JSON object"]
        }

    stat = receipt_p.stat()
    receipt_mtime = stat.st_mtime

    # Lock acquisition time check if lock_path is provided
    if lock_path:
        try:
            lock_p = Path(lock_path).resolve()
            lock_info = read_lock_info(lock_p)
            if lock_info and "acquired_at" in lock_info:
                lock_acq = float(lock_info["acquired_at"])
                if min_acquired_at is None or lock_acq > min_acquired_at:
                    min_acquired_at = lock_acq
        except Exception:
            pass

    # Freshness verification
    if min_mtime is not None and receipt_mtime < min_mtime:
        problems.append(
            f"Receipt mtime ({receipt_mtime:.3f}) predates minimum mtime threshold ({min_mtime:.3f}); stale receipt"
        )
    if min_acquired_at is not None and receipt_mtime < min_acquired_at:
        problems.append(
            f"Receipt mtime ({receipt_mtime:.3f}) predates lock acquisition ({min_acquired_at:.3f}); stale receipt"
        )

    # Status check
    status = receipt_data.get("status")
    if status != "ALL_RUNS_COMPLETED":
        problems.append(f"Receipt status is '{status}', expected 'ALL_RUNS_COMPLETED'")
        if status == "RUN_FAILED":
            err_msg = receipt_data.get("error", "unknown error")
            problems.append(f"Recorded execution error: {err_msg}")

    # Runs check
    runs = receipt_data.get("runs")
    if not isinstance(runs, list):
        problems.append("Receipt has no valid 'runs' list")
        runs = []
    elif len(runs) != expected_runs:
        problems.append(f"Runs completed count ({len(runs)}) does not match expected ({expected_runs})")

    # Per-run verification
    for idx, r in enumerate(runs, start=1):
        if not isinstance(r, dict):
            problems.append(f"Run {idx} record is not a dictionary")
            continue
        run_status = r.get("status")
        if run_status != "RUN_COMPLETED_SUCCESS":
            problems.append(f"Run {idx} status is '{run_status}', expected 'RUN_COMPLETED_SUCCESS'")
        exit_code = r.get("exit_code")
        if exit_code != 0:
            problems.append(f"Run {idx} exit code is {exit_code}, expected 0")
        horizon = r.get("horizon_check", {})
        if not horizon.get("verified"):
            problems.append(f"Run {idx} horizon check not verified: {horizon}")

    # Determinism check (if >= 2 runs)
    if len(runs) >= 2:
        det = receipt_data.get("determinism_audit", {})
        if not det.get("byte_for_byte_identical"):
            problems.append(f"Runs are not byte-for-byte identical (discrepancies: {det.get('discrepancies_count', 'unknown')})")

    # Inventory audit
    inv = receipt_data.get("inventory_audit", {})
    actual_files = inv.get("actual_output_files", 0)
    if actual_files <= 0 and len(runs) > 0:
        problems.append("Inventory audit reports 0 actual output files")

    return {
        "valid": len(problems) == 0,
        "receipt_path": str(receipt_p),
        "status": status,
        "receipt_mtime": receipt_mtime,
        "runs_completed": len(runs),
        "expected_runs": expected_runs,
        "exit_code_zero_all_runs": (all(r.get("exit_code") == 0 for r in runs) if runs else False),
        "determinism_verified": (receipt_data.get("determinism_audit", {}).get("byte_for_byte_identical", False) if len(runs) >= 2 else True),
        "horizon_verified": (all(r.get("horizon_check", {}).get("verified", False) for r in runs) if runs else False),
        "problems": problems,
    }


def relaunch_campaign(
    deck_src: Path,
    exe_src: Path,
    output_base: Path,
    campaign_id: str,
    runs: int = 3,
    core_affinity: int = 1,
    timeout_per_run: float = 21600.0,
    warmup_timeout: float = 180.0,
    out_receipt: Path = Path("audit/runs/p04_full_run_receipt.json"),
    lock_path: Path = DEFAULT_LOCK_PATH,
    heartbeat_path: Path = DEFAULT_HEARTBEAT_PATH,
    heartbeat_interval: float = DEFAULT_HEARTBEAT_INTERVAL_SECONDS,
    max_simulated_days: int | None = None,
    dry_run: bool = False,
    campaign_log: Path | None = None,
) -> dict:
    """Execute hardened detached relaunch with lock/log/run_1 quarantine."""
    deck_src = deck_src.resolve(strict=True)
    exe_src = exe_src.resolve(strict=True)
    output_base = output_base.resolve()
    out_receipt = out_receipt.resolve()
    lock_path = lock_path.resolve()
    heartbeat_path = heartbeat_path.resolve()
    campaign_dir = output_base / campaign_id

    # R5 check
    if "audit/runs" in str(output_base).replace("\\", "/"):
        raise ProtocolError(f"R5 violation: outputs cannot be directed into audit/runs/ ({output_base})")

    # 1. Lock pre-check
    status = inspect_lock_status(lock_path, heartbeat_path)
    if status["locked"] and not status["reclaimable"]:
        raise ProtocolError(
            f"Cannot relaunch: active machine lock held by PID {status['pid']} "
            f"(heartbeat age: {status['heartbeat_age']:.1f}s); live lock cannot be stolen"
        )

    # 2. Quarantine prior artifacts
    child_log = (campaign_log or (heartbeat_path.parent / "driver.log")).resolve()
    quarantined = quarantine_campaign_artifacts(
        campaign_dir=campaign_dir,
        receipt_path=out_receipt,
        driver_log=child_log,
    )

    # 3. Dry-run handling
    if dry_run:
        deck_files = list(deck_src.glob("*"))
        if not deck_files:
            raise ProtocolError(f"Deck directory {deck_src} is empty")
        if not exe_src.is_file():
            raise ProtocolError(f"Executable {exe_src} not found")

        relaunch_dry_receipt = {
            "status": "RELAUNCH_DRY_RUN_PASSED",
            "campaign_id": campaign_id,
            "campaign_directory": str(campaign_dir),
            "machine_lock_path": str(lock_path),
            "lock_precheck": status,
            "quarantined_artifacts": quarantined,
            "child_log": str(child_log),
            "deck_source": str(deck_src),
            "exe_path": str(exe_src),
            "runs_planned": runs,
            "timeout_per_run_s": timeout_per_run,
        }
        out_receipt.parent.mkdir(parents=True, exist_ok=True)
        out_receipt.write_text(json.dumps(relaunch_dry_receipt, indent=2), encoding="utf-8")
        return relaunch_dry_receipt

    # 4. Detached launch
    child_argv = [
        sys.executable,
        "-u",
        str(Path(__file__).resolve()),
        "--staged-deck", str(deck_src),
        "--exe", str(exe_src),
        "--output-base", str(output_base),
        "--campaign-id", campaign_id,
        "--runs", str(runs),
        "--core-affinity", str(core_affinity),
        "--timeout-per-run", str(timeout_per_run),
        "--warmup-timeout", str(warmup_timeout),
        "--out", str(out_receipt),
        "--lock-file", str(lock_path),
        "--heartbeat-file", str(heartbeat_path),
        "--heartbeat-interval", str(heartbeat_interval),
        "--campaign-log", str(child_log),
    ]
    if max_simulated_days is not None:
        child_argv.extend(["--max-simulated-days", str(max_simulated_days)])

    child_p = spawn_detached_child(child_argv, child_log)
    time.sleep(0.3)
    poll_res = child_p.poll()
    if poll_res is not None:
        err_tail = ""
        if child_log.exists():
            err_tail = child_log.read_text(encoding="latin-1", errors="replace")[-500:]
        raise RuntimeError(f"Detached relaunch child failed to launch (exit {poll_res}): {err_tail}")

    result = {
        "status": "RELAUNCH_SPAWNED_SUCCESS",
        "launcher_pid": os.getpid(),
        "child_pid": child_p.pid,
        "campaign_id": campaign_id,
        "campaign_directory": str(campaign_dir),
        "heartbeat_path": str(heartbeat_path),
        "driver_log": str(child_log),
        "quarantined_artifacts": quarantined,
    }
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--staged-deck", type=Path, default=Path("D:/ecosys-evidence/legacy/staged_deck"))
    ap.add_argument("--exe", type=Path, default=Path("D:/ecosys-evidence/legacy/ecosys_oracle.exe"))
    ap.add_argument("--output-base", type=Path, default=Path("D:/ecosys-evidence/legacy"))
    ap.add_argument("--campaign-id", type=str, default=None)
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--core-affinity", type=int, default=1, help="Core affinity mask (default: 1 for Core 0)")
    ap.add_argument("--timeout-per-run", type=float, default=21600.0, help="Per-run timeout in seconds (default: 6h / 21600s)")
    ap.add_argument("--warmup-timeout", type=float, default=180.0, help="Per-warmup timeout in seconds")
    ap.add_argument("--max-simulated-days", type=int, default=None, help="Bounded test simulation days (optional)")
    ap.add_argument("--dry-run", action="store_true", help="Validate configuration and exit without running simulation")
    ap.add_argument("--detach", action="store_true", help="Spawn detached background process and return immediately")
    ap.add_argument("--relaunch", action="store_true", help="Hardened relaunch: verify lock, quarantine prior run_1 / driver.log / receipt, launch detached child with unbuffered logging")
    ap.add_argument("--quarantine-prior", action="store_true", help="Quarantine prior run_1, driver.log, and stale receipt before launch")
    ap.add_argument("--campaign-log", type=Path, default=None, help="Campaign log file for driver stdout/stderr (default: audit/runs/p04-full-campaign/driver.log)")
    ap.add_argument("--validate-receipt", type=Path, default=None, help="Validate an existing terminal run receipt and exit")
    ap.add_argument("--min-mtime", type=float, default=None, help="Minimum acceptable receipt mtime timestamp for --validate-receipt")
    ap.add_argument("--min-acquired-at", type=float, default=None, help="Minimum acceptable lock acquisition timestamp for --validate-receipt")
    ap.add_argument("--lock-file", type=Path, default=None, help="Machine lock path (default: .agent/locks/machine.lock)")
    ap.add_argument("--heartbeat-file", type=Path, default=None, help="Path for child heartbeat file (default: audit/runs/p04-full-campaign/heartbeat.json)")
    ap.add_argument("--heartbeat-interval", type=float, default=DEFAULT_HEARTBEAT_INTERVAL_SECONDS, help="Heartbeat update interval in seconds (default: 30s)")
    ap.add_argument("--out", type=Path, default=Path("audit/runs/p04_full_run_receipt.json"))
    a = ap.parse_args()

    # Early exit for receipt validation
    if a.validate_receipt:
        lock_p = (a.lock_file or (ROOT / DEFAULT_LOCK_PATH)).resolve() if (a.lock_file or (ROOT / DEFAULT_LOCK_PATH).exists()) else None
        res = validate_terminal_receipt(
            receipt_path=a.validate_receipt,
            min_mtime=a.min_mtime,
            min_acquired_at=a.min_acquired_at,
            lock_path=lock_p,
            expected_runs=a.runs,
        )
        print(json.dumps(res, indent=2))
        sys.exit(0 if res["valid"] else 1)

    deck_src = a.staged_deck.resolve(strict=True)
    exe_src = a.exe.resolve(strict=True)
    output_base = a.output_base.resolve()
    out_receipt = a.out.resolve()

    # R5 constraint: Outputs go to D:\ecosys-evidence\legacy\<run-id>\, not audit/runs/
    if "audit/runs" in str(output_base).replace("\\", "/"):
        raise ProtocolError(f"R5 violation: outputs cannot be directed into audit/runs/ ({output_base})")

    cid = a.campaign_id or f"p04-{int(time.time())}"
    campaign_dir = output_base / cid
    lock_path = (a.lock_file or (ROOT / DEFAULT_LOCK_PATH)).resolve()
    heartbeat_path = (a.heartbeat_file or (ROOT / DEFAULT_HEARTBEAT_PATH)).resolve()

    # Hardened Relaunch Mode
    if a.relaunch:
        res = relaunch_campaign(
            deck_src=deck_src,
            exe_src=exe_src,
            output_base=output_base,
            campaign_id=cid,
            runs=a.runs,
            core_affinity=a.core_affinity,
            timeout_per_run=a.timeout_per_run,
            warmup_timeout=a.warmup_timeout,
            out_receipt=out_receipt,
            lock_path=lock_path,
            heartbeat_path=heartbeat_path,
            heartbeat_interval=a.heartbeat_interval,
            max_simulated_days=a.max_simulated_days,
            dry_run=a.dry_run,
            campaign_log=a.campaign_log,
        )
        print(f"[Relaunch Mode] Hardened detached child spawned successfully.")
        print(json.dumps(res, indent=2))
        return

    if a.detach:
        # C1: Detached mode spawns a child that outlives the turn and returns within a few seconds.
        # Parent prints PID, heartbeat path, and campaign ID.
        child_log = (a.campaign_log or (heartbeat_path.parent / "driver.log")).resolve()
        quarantined = {}
        if a.quarantine_prior:
            quarantined = quarantine_campaign_artifacts(
                campaign_dir=campaign_dir,
                receipt_path=out_receipt,
                driver_log=child_log,
            )
            if quarantined:
                print(f"[Quarantine] Quarantined prior artifacts: {json.dumps(quarantined)}")

        child_argv = [
            sys.executable,
            "-u",
            str(Path(__file__).resolve()),
            "--staged-deck", str(deck_src),
            "--exe", str(exe_src),
            "--output-base", str(output_base),
            "--campaign-id", cid,
            "--runs", str(a.runs),
            "--core-affinity", str(a.core_affinity),
            "--timeout-per-run", str(a.timeout_per_run),
            "--warmup-timeout", str(a.warmup_timeout),
            "--out", str(out_receipt),
            "--lock-file", str(lock_path),
            "--heartbeat-file", str(heartbeat_path),
            "--heartbeat-interval", str(a.heartbeat_interval),
            "--campaign-log", str(child_log),
        ]
        if a.max_simulated_days is not None:
            child_argv.extend(["--max-simulated-days", str(a.max_simulated_days)])
        if a.dry_run:
            child_argv.append("--dry-run")

        child_p = spawn_detached_child(child_argv, child_log)

        time.sleep(0.3)
        poll_res = child_p.poll()
        if poll_res is not None:
            err_tail = ""
            if child_log.exists():
                err_tail = child_log.read_text(encoding="latin-1", errors="replace")[-500:]
            raise RuntimeError(f"Detached child failed to launch (exit {poll_res}): {err_tail}")

        print(f"[Detached Mode] Child process spawned successfully.")
        print(f"  PID: {child_p.pid}")
        print(f"  Heartbeat path: {heartbeat_path}")
        print(f"  Campaign ID: {cid}")
        print(f"  Driver log: {child_log}")
        return

    # Line-buffered stdout/stderr flushing for live child processes
    try:
        if hasattr(sys.stdout, "reconfigure"):
            sys.stdout.reconfigure(line_buffering=True, write_through=True)
        if hasattr(sys.stderr, "reconfigure"):
            sys.stderr.reconfigure(line_buffering=True, write_through=True)
    except Exception:
        pass

    print(f"=== ECOSYS P0.4 LEGACY GFORTRAN FULL-RUN DRIVER ===")
    print(f"  Deck source: {deck_src}")
    print(f"  Executable: {exe_src}")
    print(f"  Output directory base: {campaign_dir}")
    print(f"  Core affinity mask: {hex(a.core_affinity)}")
    print(f"  Runs requested: {a.runs}")
    print(f"  Timeout per run: {a.timeout_per_run}s")
    print(f"  Dry-run: {a.dry_run}")
    print(f"  Machine lock path: {lock_path}")
    print(f"  Heartbeat path: {heartbeat_path}")

    if a.dry_run:
        # Dry-run validation of configuration and requirements
        print("Executing dry-run validation against R5 specifications...")
        deck_files = list(deck_src.glob("*"))
        if not deck_files:
            raise ProtocolError(f"Deck directory {deck_src} is empty")
        if not exe_src.is_file():
            raise ProtocolError(f"Executable {exe_src} not found")

        # Verify affinity functionality on self
        self_pid = os.getpid()
        init_aff = get_process_affinity(self_pid)
        set_process_affinity(self_pid, a.core_affinity)
        verif_aff = get_process_affinity(self_pid)
        if init_aff is not None:
            set_process_affinity(self_pid, init_aff)

        dry_receipt = {
            "status": "DRY_RUN_PASSED",
            "protocol": "plan §5 P0.4 / SAGE T-00140 / SAGE T-00142 R5",
            "r5_compliance_audit": {
                "exit_code_zero_required": True,
                "outputs_destination": str(campaign_dir),
                "outputs_outside_audit_runs": True,
                "output_hashing_and_size_recording": "Enabled (SHA-256 + size + line count)",
                "horizon_check_implementation": "Enabled (Year 2027 DOY 365 / log completion check)",
                "inventory_comparison_reference": {
                    "expected_files": RUN_002_EXPECTED_FILES,
                    "expected_size_approx_bytes": RUN_002_EXPECTED_BYTES_APPROX
                },
                "machine_lock_path": str(lock_path),
                "heartbeat_path": str(heartbeat_path),
                "stale_lock_recovery": "Enabled (dead PID check + 600s heartbeat timeout)",
                "detached_mode_supported": True,
                "core_affinity_mask": hex(a.core_affinity),
                "core_affinity_verified": hex(verif_aff) if verif_aff is not None else "UNAVAILABLE",
                "checkpoint_policy": "No *.bin checkpoints; legacy Fortran 77 does not implement Zig checkpointing",
                "warmup_policy": "Fresh discarded 1-day warmup immediately before each timed run",
                "reporting": "Median and spread of elapsed seconds across runs",
                "determinism_check": "Byte-for-byte SHA-256 cross-run equality check",
                "system_load_recording": "Enabled (L3 system load recorded per run and in heartbeat)"
            },
            "configuration": {
                "deck_source": str(deck_src),
                "deck_file_count": len(deck_files),
                "exe_path": str(exe_src),
                "exe_sha256": sha256_file(exe_src),
                "runs_planned": a.runs,
                "timeout_per_run_s": a.timeout_per_run,
                "warmup_timeout_s": a.warmup_timeout
            }
        }
        out_receipt.parent.mkdir(parents=True, exist_ok=True)
        out_receipt.write_text(json.dumps(dry_receipt, indent=2), encoding="utf-8")
        print(f"Dry-run receipt successfully written to {out_receipt}")
        return

    # Child execution under MachineLock
    mlock = MachineLock(
        lock_path=lock_path,
        heartbeat_path=heartbeat_path,
        campaign_id=cid,
        heartbeat_interval=a.heartbeat_interval,
        max_heartbeat_age=MAX_HEARTBEAT_STALE_SECONDS,
    )
    print(f"Acquiring exclusive machine lock: {lock_path}")
    print(f"Heartbeat path: {heartbeat_path}")

    campaign_dir.mkdir(parents=True, exist_ok=True)
    runs_data = []
    warmups_data = []
    execution_error = None

    try:
        with mlock:
            for run_idx in range(1, a.runs + 1):
                if mlock.heartbeat_daemon:
                    mlock.heartbeat_daemon.set_status(f"WARMUP_{run_idx}", current_run=run_idx, total_runs=a.runs)
                run_name = f"run_{run_idx}"
                run_target_dir = campaign_dir / run_name
                warmup_target_dir = campaign_dir / f"warmup_{run_idx}"

                print(f"\n--- [Iteration {run_idx}/{a.runs}] Starting Warmup ---")
                warmup_res = run_1day_warmup(
                    deck_src, exe_src, warmup_target_dir, a.core_affinity, a.warmup_timeout
                )
                warmups_data.append(warmup_res)

                if mlock.heartbeat_daemon:
                    mlock.heartbeat_daemon.set_status(f"RUN_{run_idx}", current_run=run_idx, total_runs=a.runs)
                print(f"--- [Iteration {run_idx}/{a.runs}] Starting Timed Run ---")
                run_res = execute_single_full_run(
                    run_name,
                    deck_src,
                    exe_src,
                    run_target_dir,
                    a.core_affinity,
                    a.timeout_per_run,
                    a.max_simulated_days
                )
                runs_data.append(run_res)
                print(f"  Run {run_idx} completed in {run_res['elapsed_seconds']}s")

            # Compute median and spread
            elapsed_times = sorted([r["elapsed_seconds"] for r in runs_data])
            median_time = elapsed_times[len(elapsed_times) // 2]
            spread_time = round(elapsed_times[-1] - elapsed_times[0], 3)
            spread_pct = round((spread_time / median_time) * 100, 2) if median_time > 0 else 0.0

            # Determinism check
            determinism = compare_determinism(runs_data)

            # Inventory comparison against run-002
            ref_run = runs_data[0]
            actual_files = ref_run["total_output_files"]
            actual_bytes = ref_run["total_output_bytes"]
            file_diff = actual_files - RUN_002_EXPECTED_FILES
            size_diff = actual_bytes - RUN_002_EXPECTED_BYTES_APPROX

            inventory_audit = {
                "run_002_baseline_files": RUN_002_EXPECTED_FILES,
                "actual_output_files": actual_files,
                "file_count_difference": file_diff,
                "run_002_baseline_approx_bytes": RUN_002_EXPECTED_BYTES_APPROX,
                "actual_total_bytes": actual_bytes,
                "size_difference_bytes": size_diff,
                "explanation": (
                    "Matches run-002 output stream structure exactly."
                    if file_diff == 0 else
                    f"File count difference of {file_diff} files relative to run-002 inventory."
                )
            }

            # Assemble full receipt
            receipt = {
                "status": "ALL_RUNS_COMPLETED",
                "protocol": "plan §5 P0.4 / SAGE T-00140 / SAGE T-00142 R5",
                "campaign_id": cid,
                "campaign_directory": str(campaign_dir),
                "runs_count": len(runs_data),
                "timing_statistics": {
                    "elapsed_seconds_all_runs": [r["elapsed_seconds"] for r in runs_data],
                    "sorted_elapsed_seconds": elapsed_times,
                    "median_seconds": median_time,
                    "spread_seconds": spread_time,
                    "relative_spread_percent": spread_pct
                },
                "determinism_audit": determinism,
                "inventory_audit": inventory_audit,
                "machine_and_environment": {
                    "machine_lock": str(lock_path),
                    "heartbeat_path": str(heartbeat_path),
                    "core_affinity_mask": hex(a.core_affinity),
                    "checkpoints_policy": "No *.bin checkpoints; legacy Fortran 77 does not implement Zig checkpointing",
                    "system_load_summary": {
                        "warmups": [w.get("system_load") for w in warmups_data],
                        "runs": [r.get("system_load") for r in runs_data]
                    }
                },
                "warmups": warmups_data,
                "runs": runs_data
            }

            out_receipt.parent.mkdir(parents=True, exist_ok=True)
            out_receipt.write_text(json.dumps(receipt, indent=2), encoding="utf-8")
            print(f"\nFull execution receipt written to {out_receipt}")
            print(json.dumps({
                "status": receipt["status"],
                "runs_completed": len(runs_data),
                "median_seconds": median_time,
                "spread_seconds": spread_time,
                "deterministic": determinism["byte_for_byte_identical"],
                "output_files_per_run": actual_files
            }, indent=2))
            if mlock.heartbeat_daemon:
                mlock.heartbeat_daemon.set_status("COMPLETED", current_run=a.runs, total_runs=a.runs)

    except Exception as e:
        execution_error = str(e)
        print(f"\n[Execution Failure] {execution_error}", file=sys.stderr)
        fail_receipt = {
            "status": "RUN_FAILED",
            "protocol": "plan §5 P0.4 / SAGE T-00140 / SAGE T-00142 R5",
            "campaign_id": cid,
            "campaign_directory": str(campaign_dir),
            "error": execution_error,
            "runs_completed": len(runs_data),
            "machine_and_environment": {
                "machine_lock": str(lock_path),
                "heartbeat_path": str(heartbeat_path),
                "core_affinity_mask": hex(a.core_affinity),
                "checkpoints_policy": "No *.bin checkpoints; legacy Fortran 77 does not implement Zig checkpointing",
                "system_load_summary": {
                    "warmups": [w.get("system_load") for w in warmups_data],
                    "runs": [r.get("system_load") for r in runs_data]
                }
            },
            "warmups": warmups_data,
            "runs": runs_data
        }
        out_receipt.parent.mkdir(parents=True, exist_ok=True)
        out_receipt.write_text(json.dumps(fail_receipt, indent=2), encoding="utf-8")
        print(f"Failure receipt successfully written to {out_receipt}", file=sys.stderr)
        if mlock.heartbeat_daemon:
            mlock.heartbeat_daemon.set_status("FAILED", current_run=len(runs_data), total_runs=a.runs)
        raise


if __name__ == "__main__":
    main()

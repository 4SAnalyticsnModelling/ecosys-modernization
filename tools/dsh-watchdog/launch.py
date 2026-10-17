#!/usr/bin/env python3
"""External dsh supervisor: owns one child, never compacts or races its loop."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from urllib.request import urlopen

REPO = Path(__file__).resolve().parents[2]
ROOT = REPO / 'watchdog'


def environment():
    env = dict(os.environ)
    for key, folder in {'TMPDIR':'.tmp','XDG_CACHE_HOME':'.cache','UV_CACHE_DIR':'.uv-cache',
                        'ZIG_GLOBAL_CACHE_DIR':'ecosys-ng/.zig-cache-global'}.items():
        location = REPO / folder
        location.mkdir(parents=True, exist_ok=True)
        env[key] = str(location)
    env.update(DSH_HOME=str(ROOT / 'home'), DSH_TUI_SESSION_ROOT=str(ROOT / 'sessions'),
               DSH_WATCHDOG_ROOT=str(ROOT), DSH_TELEMETRY_MODE='DISABLED',
               DSH_LOCAL_MLX_SESSION='1', DSH_TUI_WORKSPACE_TARGET=str(REPO),
               DSH_WATCHDOG_TUI_DATA=str(ROOT / 'tui-data'))
    return env


def rotate(file, limit=4 * 1024 * 1024):
    if file.exists() and file.stat().st_size >= limit:
        for n in range(4, 0, -1):
            src = file.with_name(file.name + (f'.{n}' if n else ''))
            dst = file.with_name(file.name + f'.{n+1}')
            if src.exists():
                if n == 4:
                    src.unlink()
                else:
                    src.replace(dst)
        file.replace(file.with_name(file.name + '.1'))


def health(state, now, stall):
    if state.get('schema') != 1 or not isinstance(state.get('sessions'), dict):
        raise ValueError('Invalid watchdog state; refusing reset')
    for s in state['sessions'].values():
        if s.get('phase') == 'blocked':
            return 'blocked checkpoint: ' + str(s.get('checkpoint'))
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--resume', help='Exact session ID; original JSONL is retained')
    parser.add_argument('--stall-seconds', type=int, default=28800,
                        help='No session-file progress; default 8h accommodates 2h local inference')
    args, extra = parser.parse_known_args()
    os.chdir(REPO)
    env = environment()
    receipt = json.loads((ROOT / 'installation.json').read_text())
    env['DSH_WATCHDOG_RUNTIME'] = receipt['runtime']
    env['DSH_WATCHDOG_AUTO_RESUME'] = '1'
    state = json.loads((ROOT / 'state.json').read_text())
    problem = health(state, time.time(), args.stall_seconds)
    if problem:
        sys.exit(problem + '; see README recovery procedure')
    pending = [s for s in state['sessions'].values() if s.get('phase') in ('checkpointing','compacting')]
    if pending:
        sys.exit('Interrupted compaction: preserve state and reconcile checkpoint before resume')
    if args.check:
        print(json.dumps({'installation':receipt,'stateValid':True}, indent=2))
        return 0
    # The existing gateway manager writes outside this repository. Never start
    # it implicitly; require its owner to bring the local route up separately.
    try:
        with urlopen('http://127.0.0.1:8090/v1/models', timeout=5) as response:
            models = json.load(response)
        available = {m['id'] for m in models['data']}
        required = {m['id'] for m in receipt['models']}
        if not required.issubset(available):
            sys.exit('Gateway catalog differs; rerun setup after verifying routes')
    except OSError as error:
        sys.exit(f'Local model gateway unavailable: {error}. No session was started.')
    lock = (ROOT / 'supervisor.lock').open('a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit('A watchdog supervisor already owns this workspace')
    if args.resume:
        if args.resume not in state['sessions']:
            sys.exit('Unknown watchdog session ID; refusing a guessed recovery')
        env['DSH_TUI_RESUME_SESSION'] = args.resume
    elif state.get('currentSession') in state['sessions']:
        env['DSH_TUI_RESUME_SESSION'] = state['currentSession']
    elif state['sessions']:
        sys.exit('Multiple or ambiguous sessions: select --resume SESSION_ID explicitly')
    command = ['node', str(Path(receipt['runtime']) / 'node_modules/@deepseek-ai/dsh/lib/bin.js'),
               '--profile','dsh-tui', *extra]
    # TUI keeps terminal ownership; diagnostics rotate separately. Full native
    # session JSONL and checkpoint archives are never rotated away.
    def run_child():
        child = subprocess.Popen(command, env=env, cwd=REPO, start_new_session=False)
        stopping = False
    
        def stop(signum, _frame):
            nonlocal stopping
            stopping = True
            child.send_signal(signum)
        for sig in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, stop)
        signal.signal(signal.SIGINT, lambda *_: None)  # TUI receives terminal Ctrl-C
        last_progress = time.monotonic()
        latest = None
        diagnostic = ROOT / 'supervisor.jsonl'
        last_gateway_check, gateway_failures = 0, 0
        while child.poll() is None:
            time.sleep(2)
            try:
                s = json.loads((ROOT / 'state.json').read_text())
                problem = health(s, time.time(), args.stall_seconds)
                fingerprint = [(str(f), f.stat().st_mtime_ns, f.stat().st_size)
                               for f in (ROOT / 'sessions').rglob('*') if f.is_file()]
                if fingerprint != latest:
                    last_progress, latest = time.monotonic(), fingerprint
                if time.monotonic() - last_progress > args.stall_seconds:
                    problem = 'No session progress; stalled inference/tool loop'
            except (OSError, ValueError) as error:
                problem = 'Persistence unavailable: ' + str(error)
            if time.monotonic() - last_gateway_check >= 30:
                last_gateway_check = time.monotonic()
                try:
                    with urlopen('http://127.0.0.1:8090/v1/models', timeout=3) as response:
                        json.load(response)
                    gateway_failures = 0
                except (OSError, ValueError):
                    gateway_failures += 1
                if gateway_failures >= 3:
                    problem = 'Local gateway failed three consecutive health checks'
            if problem and not stopping:
                rotate(diagnostic)
                with diagnostic.open('a') as log:
                    log.write(json.dumps({'at':time.time(),'problem':problem,'pid':child.pid})+'\n')
                child.terminate()
                try:
                    child.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    child.kill()
                return 1, True  # Preserve exact session; never issue a duplicate task.
        return child.returncode, stopping
    supervisor_file = ROOT / 'supervisor-state.json'
    supervisor = json.loads(supervisor_file.read_text()) if supervisor_file.exists() else {'restarts':0}
    while True:
        code, stopped = run_child()
        if code == 0 or stopped:
            return code
        current = json.loads((ROOT / 'state.json').read_text())
        session_id = current.get('currentSession')
        session = current['sessions'].get(session_id, {})
        if session.get('phase') != 'running' or supervisor['restarts'] >= 2:
            return code
        supervisor['restarts'] += 1
        # Atomic checkpoint independent of the harness process.
        temp = supervisor_file.with_suffix('.tmp')
        with temp.open('w') as out:
            json.dump(supervisor, out)
            out.flush()
            os.fsync(out.fileno())
        temp.replace(supervisor_file)
        env['DSH_TUI_RESUME_SESSION'] = session_id



if __name__ == '__main__':
    sys.exit(main())

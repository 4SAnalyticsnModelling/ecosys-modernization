"""Supervise one future worker with durable reconciliation and unlimited crash recovery."""
from __future__ import annotations
import argparse
import fcntl
import uuid
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from workflow import ROOT, ProtocolError, atomic, encoded, inside, load, lock
from project_runtime import environment, owned_alive, process_identity
from pickup import collect
from completion import validate


def check_config(config: dict) -> None:
    for key in ['command', 'recovery_command']:
        argv = config.get(key)
        if not isinstance(argv, list) or (key == 'command' and not argv) or not all(isinstance(x,str) and x for x in argv):
            raise ProtocolError(key + ' must be verified argv (command cannot be empty)')
    initial, maximum = config.get('backoff_initial_seconds',1), config.get('backoff_max_seconds',60)
    if not (isinstance(initial,(int,float)) and isinstance(maximum,(int,float)) and 0 < initial <= maximum <= 60):
        raise ProtocolError('backoff must satisfy 0 < initial <= maximum <= 60 seconds')


def supervise(root: Path, config: dict, *, stop_event=None, sleep=time.sleep, max_launches=None) -> int:
    """max_launches is a test seam only, never a production CLI limit."""
    check_config(config)
    runtime=inside(root,'.agent/runtime');runtime.mkdir(parents=True,exist_ok=True)
    state_file=runtime/'supervisor.json'; packet=runtime/'recovery.json'
    env=environment(root);env.update(ECOSYS_PROJECT_ROOT=str(root), ECOSYS_RECOVERY_PACKET=str(packet))
    stopping=False;child=None;launches=0;delay=config.get('backoff_initial_seconds',1)
    def stop(_sig,_frame):
        nonlocal stopping
        stopping=True
        if child and child.poll() is None:child.terminate()
    if stop_event is None:
        for sig in [signal.SIGINT,signal.SIGTERM,signal.SIGHUP]:signal.signal(sig,stop)
    def stopped():return stopping or (stop_event is not None and stop_event.is_set())
    with lock(runtime/'supervisor.lock'):
        # A crashed supervisor may leave its worker alive; observe it before creating another.
        try:
            previous=load(state_file) if state_file.exists() else {}
        except (OSError,ValueError) as e:
            preserved=runtime/('supervisor-corrupt-'+str(uuid.uuid4())+'.json')
            if state_file.exists():atomic(preserved,state_file.read_bytes())
            previous={'status':'RECONCILE','state_error':str(e),'preserved_state':str(preserved)}
        while owned_alive(previous) and not stopped():sleep(2)
        while not stopped():
            if not validate(root):return 0
            if max_launches is not None and launches >= max_launches:return 1
            lease=None
            try:
                lease=os.open(runtime/'worker-lease.lock',os.O_CREAT|os.O_RDWR,0o600)
                try:fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB)
                except BlockingIOError:
                    os.close(lease);lease=None;sleep(2);continue
                atomic(packet,encoded({'pickup':collect(root),'previous_worker':previous,
                    'action':'Read protocol; reconcile unfinished operations and existing jobs. Resume open cycle. '
                             'Do not replay side effects blindly. Decide/replan failures and continue until F1–F7.'}))
                # Optional infrastructure repair is idempotent argv, separate from scientific retries.
                if launches and config['recovery_command']:
                    with (runtime/'recovery.log').open('ab') as log:
                        repair=subprocess.run(config['recovery_command'],cwd=root,env=env,stdout=log,stderr=log)
                    if repair.returncode:raise ProtocolError('recovery command failed: '+str(repair.returncode))
                with (runtime/'worker.log').open('ab') as log:
                    child=subprocess.Popen(config['command'],cwd=root,env=env,stdin=subprocess.DEVNULL,
                                           stdout=log,stderr=log,start_new_session=True,pass_fds=(lease,))
                    os.close(lease);lease=None
                    previous={'status':'RUNNING','pid':child.pid,'process_start':process_identity(child.pid),
                              'argv':config['command'],'launch':previous.get('launch',0)+1,'started':time.time()}
                    atomic(state_file,encoded(previous));launches+=1
                    while child.poll() is None and not stopped():sleep(1)
                    if stopped() and child.poll() is None:
                        child.terminate()
                        try:child.wait(timeout=30)
                        except subprocess.TimeoutExpired:child.kill();child.wait()
                    previous.update(status='STOPPED' if stopped() else 'EXITED',exit_code=child.wait(),ended=time.time())
                    atomic(state_file,encoded(previous))
            except (OSError,ValueError,ProtocolError) as e:
                if lease is not None:os.close(lease)
                previous={'status':'RETRY','error':str(e),'launch':previous.get('launch',0),'ended':time.time()}
                atomic(state_file,encoded(previous))
            if not stopped():sleep(delay);delay=min(delay*2,config.get('backoff_max_seconds',60))
    return 130


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--config',default='.agent/worker.json')
    p.add_argument('--check',action='store_true');a=p.parse_args()
    try:
        config=load(inside(ROOT,a.config));check_config(config)
        if a.check:print('Worker argv valid; no worker launched.');return 0
        return supervise(ROOT,config)
    except (OSError,ValueError,ProtocolError) as e:
        print(str(e),file=sys.stderr);return 2
if __name__ == '__main__':raise SystemExit(main())

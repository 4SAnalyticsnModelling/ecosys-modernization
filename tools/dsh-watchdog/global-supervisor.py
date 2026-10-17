#!/usr/bin/env python3
"""Global dsh supervisor; the in-process native engine alone compacts."""
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

HERE=Path(__file__).resolve().parent
ROOT=Path.cwd()/'.dsh-watchdog'
INSTALLED=HERE.parents[1]


def save(file,data):
    temp=file.with_suffix('.tmp')
    with temp.open('w') as out:
        json.dump(data,out,indent=2);out.flush();os.fsync(out.fileno())
    temp.replace(file)
    fd=os.open(file.parent,os.O_RDONLY)
    try:os.fsync(fd)
    finally:os.close(fd)


def load_state():
    state=json.loads((ROOT/'state.json').read_text())
    if state.get('schema')!=1 or not isinstance(state.get('sessions'),dict):
        raise ValueError('Invalid watchdog state; refusing reset')
    return state


def terminate(child):
    if child.poll() is not None:return
    child.terminate()
    try:child.wait(timeout=45)
    except subprocess.TimeoutExpired:child.kill();child.wait()


def diagnostic(reason):
    log=ROOT/'supervisor.jsonl'
    if log.exists() and log.stat().st_size>4*1024*1024:
        for index in range(4,0,-1):
            source=ROOT/f'supervisor.jsonl.{index}'
            if source.exists():
                if index==4:source.unlink()
                else:source.replace(ROOT/f'supervisor.jsonl.{index+1}')
        log.replace(ROOT/'supervisor.jsonl.1')
    with log.open('a') as out:out.write(json.dumps({'time':time.time(),'reason':reason})+'\n')


def main():
    if len(sys.argv)<2:sys.exit('Expected original launcher and arguments')
    version=json.loads((INSTALLED/'runtime/node_modules/@deepseek-ai/dsh/package.json').read_text())['version']
    if version!='0.2.0-rc.2':sys.exit('Unverified dsh version '+version+'; revalidate watchdog contracts before use')
    ROOT.mkdir(parents=True,exist_ok=True)
    lock=(ROOT/'supervisor.lock').open('a')
    try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:sys.exit('A dsh watchdog already owns this workspace')
    try:
        state_file=ROOT/'state.json'
        if not state_file.exists():
            if ((ROOT/'sessions').exists() and any((ROOT/'sessions').iterdir())) or (ROOT/'checkpoints').exists():
                sys.exit('Missing watchdog state with prior sessions; refusing reset')
            (ROOT/'sessions').mkdir(exist_ok=True)
            for file in ['progress.md','decisions.md','issues.md']:
                dest=ROOT/file
                if not dest.exists():dest.write_text((HERE/'templates'/file).read_text())
            save(state_file,{'schema':1,'sessions':{}})
        headless=any(arg=='headless' or arg=='--profile=headless' for arg in sys.argv[2:])
        env=dict(os.environ,DSH_WATCHDOG_SUPERVISED='1',DSH_WATCHDOG_ROOT=str(ROOT),
                 DSH_WATCHDOG_RUNTIME=str(INSTALLED/'runtime'),DSH_WATCHDOG_AUTO_RESUME='0' if headless else '1',
                 DSH_TUI_SESSION_ROOT=str(ROOT/'sessions'),DSH_TELEMETRY_MODE='DISABLED')
        for key,sub in [('TMPDIR','tmp'),('XDG_CACHE_HOME','cache'),('UV_CACHE_DIR','uv-cache'),('HF_HOME','hf-cache')]:
            dest=ROOT/sub;dest.mkdir(exist_ok=True);env[key]=str(dest)
        sf=ROOT/'supervisor-state.json'
        supervisor=json.loads(sf.read_text()) if sf.exists() else {'restarts':0}
        subprocess.run(['node',str(INSTALLED/'configure.mjs')],check=True,env=env,stdout=subprocess.DEVNULL)
        while True:
            state=load_state()
            for s in state['sessions'].values():
                if s.get('phase') in ['blocked','checkpointing','compacting']:
                    sys.exit('Checkpoint reconciliation required: '+str(s.get('checkpoint')))
            if not headless and state.get('currentSession'):
                env['DSH_TUI_RESUME_SESSION']=state['currentSession']
            child=subprocess.Popen(sys.argv[1:],env=env)
            stopping=False
            def stop(sig,_frame):
                nonlocal stopping
                stopping=True
                child.send_signal(sig)
            for sig in (signal.SIGTERM,signal.SIGHUP):signal.signal(sig,stop)
            signal.signal(signal.SIGINT,lambda *_:None)
            try:
                while child.poll() is None:
                    time.sleep(2)
                    reason=None
                    try:
                        state=load_state()
                        if any(s.get('phase')=='blocked' for s in state['sessions'].values()):reason='blocked checkpoint'
                    except (OSError,ValueError) as error:
                        reason='Persistence unavailable: '+str(error)
                    if reason:
                        stopping=True
                        try:diagnostic(reason)
                        finally:terminate(child)
            finally:
                terminate(child)
            if child.returncode==0:
                supervisor['restarts']=0;save(sf,supervisor)
                return 0
            if stopping or headless:return child.returncode
            state=load_state()
            current=state['sessions'].get(state.get('currentSession'),{})
            if current.get('phase')!='running' or supervisor['restarts']>=2:return child.returncode
            supervisor['restarts']+=1;save(sf,supervisor)
    finally:
        lock.close()



if __name__=='__main__':sys.exit(main())

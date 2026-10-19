#!/usr/bin/env python3
"""Global dsh supervisor; the in-process native engine alone compacts."""
import fcntl
import json
import os
from pathlib import Path
import signal
import shlex
import subprocess
import sys
import time
import uuid
import hashlib

HERE=Path(__file__).resolve().parent
ROOT=Path.cwd()/'.dsh-watchdog'
INSTALLED=HERE.parents[1]
sys.dont_write_bytecode=True
sys.path.insert(0,str(HERE))
import isolation


def internal_handoff(parent_pid, env):
    """Only the installed TUI's immediate Node child shares its supervisor."""
    root=Path(env.get('DSH_WATCHDOG_ROOT',''))
    if env.get('DSH_WATCHDOG_SUPERVISED') != '1' or not root.is_absolute():return False
    if not (root/'state.json').is_file() or env.get('DSH_TUI_SESSION_ROOT') != str(root/'sessions'):return False
    try:
        command=subprocess.check_output(['/bin/ps','-p',str(int(parent_pid)),'-o','command='],text=True)
        argv=shlex.split(command)
    except (ValueError,OSError,subprocess.CalledProcessError):return False
    if len(argv)<2 or Path(argv[0]).name != 'node':return False
    script=Path(argv[1])
    isolated=env.get('DSH_ISOLATED_TUI_ENTRY')
    if isolated and script in (Path(isolated),Path(isolated).parents[1]/'lib/types/dsh-adapter/host-entry.js'):
        return True
    profile_root=Path.home()/'.dsh/profiles'
    if not script.is_absolute() or not script.is_relative_to(profile_root):return False
    relative=script.relative_to(profile_root).parts
    suffixes=[('node_modules','@deepseek-harness-tui','dsh-tui','bin','dsh-tui.js'),
              ('node_modules','@deepseek-harness-tui','dsh-tui','lib','types','dsh-adapter','host-entry.js')]
    return any(relative[1:] == suffix for suffix in suffixes)


def select_instance(base, arguments):
    """Fresh launches own fresh state; recovery is an explicit selection."""
    args=list(arguments)
    resume=None
    for index,arg in enumerate(args):
        if arg == '--watchdog-resume' or arg.startswith('--watchdog-resume='):
            if arg == '--watchdog-resume':
                if index+1 >= len(args):raise ValueError('--watchdog-resume needs an instance ID or legacy')
                resume=args[index+1];del args[index:index+2]
            else:
                resume=arg.split('=',1)[1];del args[index]
            break
    if any(arg.startswith('--watchdog-resume') for arg in args):
        raise ValueError('Specify --watchdog-resume only once')
    if resume is not None:
        if resume != 'legacy':
            try:
                if str(uuid.UUID(resume)) != resume:raise ValueError()
            except ValueError:raise ValueError('Invalid watchdog instance ID') from None
        root=base if resume == 'legacy' else base/'instances'/resume
        if not (root/'state.json').is_file():raise ValueError('No saved watchdog instance: '+resume)
        return root,args,False
    root=base/'instances'/str(uuid.uuid4())
    root.mkdir(parents=True,exist_ok=False)
    return root,args,True


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


def selected_records(state):
    if state.get('layout') != 'per-agent-v1':return list(state['sessions'].values())
    current=state.get('currentSession')
    if not current:return []
    key=hashlib.sha256(current.encode()).hexdigest()
    file=ROOT/'agents'/key/'state.json'
    data=json.loads(file.read_text())
    if data.get('schema')!=1 or current not in data.get('sessions',{}):
        raise ValueError('Active session persistence unavailable; refusing reset')
    return [data['sessions'][current]]


def prepare_environment(root,installed):
    runtime=root/'runtime';runtime.mkdir(exist_ok=True)
    ready=runtime/'gateway.json';ready.unlink(missing_ok=True)
    env=isolation.private_env(root,os.environ)
    log=(runtime/'gateway.log').open('ab',buffering=0)
    gateway=subprocess.Popen([sys.executable,str(HERE/'isolation.py'),'gateway',str(runtime),str(installed),str(ready)],
                             env=env,stdout=log,stderr=subprocess.STDOUT)
    try:
        while not ready.exists():
            if gateway.poll() is not None:raise RuntimeError('Private gateway failed: '+str(runtime/'gateway.log'))
            time.sleep(.1)
        endpoint='http://127.0.0.1:'+str(json.loads(ready.read_text())['port'])
        env=isolation.prepare_launch(root,installed,Path.home(),endpoint)
        isolation.configure_profiles(root,installed,endpoint,env)
        return env,gateway,log
    except BaseException:
        if gateway.poll() is None:gateway.terminate()
        gateway.wait();log.close();raise


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
    global ROOT
    if len(sys.argv)<2:sys.exit('Expected original launcher and arguments')
    if sys.argv[1] == '--watchdog-internal-handoff':
        return 0 if len(sys.argv)==3 and internal_handoff(sys.argv[2],os.environ) else 1
    version=json.loads((INSTALLED/'runtime/node_modules/@deepseek-ai/dsh/package.json').read_text())['version']
    if version!='0.2.0-rc.2':sys.exit('Unverified dsh version '+version+'; revalidate watchdog contracts before use')
    base=ROOT
    try:ROOT,arguments,fresh=select_instance(base,sys.argv[2:])
    except ValueError as error:sys.exit(str(error))
    ROOT.mkdir(parents=True,exist_ok=True)
    gateway=None;gateway_log=None
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
            save(state_file,{'schema':1,'sessions':{},'layout':'per-agent-v1'})
        save(ROOT/'instance.json',{'id':ROOT.name if ROOT != base else 'legacy',
             'root':str(ROOT),'herdrSession':os.environ.get('HERDR_SESSION'),
             'herdrPane':os.environ.get('HERDR_PANE_ID'),'freshLaunch':fresh})
        print('Watchdog instance: '+('legacy' if ROOT == base else ROOT.name),file=sys.stderr,flush=True)
        headless=any(arg=='headless' or arg=='--profile=headless' for arg in arguments)
        # Public installed launchers use private config/UI/service state. Test or
        # explicitly supplied external executables retain their existing argv.
        isolated=Path(sys.argv[1]).name in ['original-dsh','original-dst'] and Path(sys.argv[1]).is_absolute()
        if isolated:
            for s in selected_records(load_state()):
                if s.get('phase') in ['blocked','checkpointing','compacting']:
                    sys.exit('Checkpoint reconciliation required: '+str(s.get('checkpoint')))
            env,gateway,gateway_log=prepare_environment(ROOT,INSTALLED)
        else:env=dict(os.environ)
        env.update(DSH_WATCHDOG_SUPERVISED='1',DSH_WATCHDOG_ROOT=str(ROOT),
                 DSH_WATCHDOG_RUNTIME=str(INSTALLED/'runtime'),DSH_WATCHDOG_AUTO_RESUME='0' if headless else '1',
                 DSH_TUI_SESSION_ROOT=str(ROOT/'sessions'),DSH_TELEMETRY_MODE='DISABLED')
        env.pop('DSH_TUI_RESUME_SESSION',None)
        for key,sub in [('TMPDIR','tmp'),('XDG_CACHE_HOME','cache'),('UV_CACHE_DIR','uv-cache'),('HF_HOME','hf-cache')]:
            dest=ROOT/sub;dest.mkdir(exist_ok=True);env[key]=str(dest)
        sf=ROOT/'supervisor-state.json'
        supervisor=json.loads(sf.read_text()) if sf.exists() else {'restarts':0}
        if not isolated:subprocess.run(['node',str(INSTALLED/'configure.mjs')],check=True,env=env,stdout=subprocess.DEVNULL)
        while True:
            state=load_state()
            for s in selected_records(state):
                if s.get('phase') in ['blocked','checkpointing','compacting']:
                    sys.exit('Checkpoint reconciliation required: '+str(s.get('checkpoint')))
            if not headless and state.get('currentSession'):
                env['DSH_TUI_RESUME_SESSION']=state['currentSession']
            command=[sys.argv[1],*arguments]
            if isolated:
                entry=env['DSH_ISOLATED_TUI_ENTRY'] if Path(sys.argv[1]).name=='original-dst' else str(INSTALLED/'runtime/node_modules/.bin/dsh')
                command=['node',entry,*arguments]
            child=subprocess.Popen(command,env=env)
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
                        # Native per-agent gates stop only their own turn. Keep
                        # the TUI alive so another conversation can still work.
                        if state.get('layout')!='per-agent-v1' and any(s.get('phase')=='blocked' for s in selected_records(state)):
                            reason='blocked checkpoint'
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
            records=selected_records(state)
            current=records[0] if records else {}
            if current.get('phase')!='running':return child.returncode
            supervisor['restarts']+=1;save(sf,supervisor)
            time.sleep(min(60,2**min(supervisor['restarts'],6)))
    finally:
        if gateway is not None:
            if gateway.poll() is None:gateway.terminate()
            gateway.wait()
            gateway_log.close()
        lock.close()



if __name__=='__main__':sys.exit(main())

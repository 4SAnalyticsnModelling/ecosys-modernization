"""Private mutable harness/config/runtime namespaces; installed code/weights are inputs."""
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def private_env(root, original):
    env=dict(original)
    for key,sub in [('TMPDIR','tmp'),('XDG_CACHE_HOME','cache'),('XDG_CONFIG_HOME','config'),
                    ('XDG_DATA_HOME','data'),('XDG_STATE_HOME','state'),('UV_CACHE_DIR','uv-cache'),
                    ('HF_HOME','hf-cache'),('NODE_COMPILE_CACHE','node-cache'),('PYTHONPYCACHEPREFIX','pycache'),
                    ('MPLCONFIGDIR','matplotlib'),('TORCH_HOME','torch-cache')]:
        dest=root/sub;dest.mkdir(parents=True,exist_ok=True);env[key]=str(dest)
    env['PYTHONDONTWRITEBYTECODE']='1'
    return env


def copy_profiles(root, source_home):
    target=root/'dsh/profiles'
    if target.exists():
        if not (target/'.complete').is_file():raise ValueError('Incomplete private profile preparation; preserve and reconcile')
        return
    target.mkdir(parents=True)
    for profile in (source_home/'.dsh/profiles').iterdir():
        if profile.name=='node_modules':
            (target/profile.name).symlink_to(profile.resolve(),target_is_directory=True)
            continue
        if not profile.is_dir():continue
        dest=target/profile.name;dest.mkdir()
        for item in profile.iterdir():
            if item.name=='node_modules':
                modules=dest/item.name;modules.mkdir()
                for dependency in item.iterdir():
                    if dependency.name=='@deepseek-harness-tui':
                        group=modules/dependency.name;group.mkdir()
                        for package in dependency.iterdir():
                            (group/package.name).symlink_to(root/'tui' if package.name=='dsh-tui' else package.resolve(),target_is_directory=True)
                    else:(modules/dependency.name).symlink_to(dependency.resolve(),target_is_directory=dependency.is_dir())
            elif item.is_file() and item.suffix in ('.json','.yaml','.yml'):
                shutil.copyfile(item,dest/item.name)
    if not (target/'node_modules').exists():
        (target/'node_modules').symlink_to(source_home/'.local/share/deepseek-harness/runtime/node_modules',target_is_directory=True)
    (target/'.complete').write_text('1\n')


def copy_tui(root, source_home):
    target=root/'tui'
    if target.exists():
        if not (target/'.complete').is_file():raise ValueError('Incomplete private TUI preparation; preserve and reconcile')
        return target/'bin/dsh-tui.js'
    source=source_home/'.dsh/profiles/dsh-tui/node_modules/@deepseek-harness-tui/dsh-tui'
    shutil.copytree(source,target,ignore=shutil.ignore_patterns('node_modules','.git'))
    if (source/'node_modules').exists():
        (target/'node_modules').symlink_to((source/'node_modules').resolve(),target_is_directory=True)
    # Dependencies are installed code. Preferences/history are exclusively private.
    dependencies=root/'node_modules';dependencies.mkdir()
    for modules in [source_home/'.local/share/deepseek-harness/runtime/node_modules',source_home/'.dsh/profiles/dsh-tui/node_modules']:
        for dependency in modules.iterdir():
            if not (dependencies/dependency.name).exists():
                (dependencies/dependency.name).symlink_to(dependency.resolve(),target_is_directory=dependency.is_dir())
    for file in target.rglob('*.js'):
        text=file.read_text()
        patched=re.sub(r"join\((?:homedir|homeDir)\(\),\s*['\"]\.dsh-tui['\"]",'join(process.env.DSH_TUI_DATA_DIR',text)
        if patched!=text:file.write_text(patched)
    switch=target/'lib/types/dsh-adapter/channel/model-switch.js'
    text=switch.read_text()
    marker='        // Assembly captures this complete route'
    if text.count(marker)!=1:raise ValueError('Unverified TUI model-switch contract')
    text=text.replace(marker,"        if (!await deps.newSession()) return false;\n"+marker)
    switch.write_text(text)
    extensions=target/'lib/types/dsh-adapter/channel/extensions.js'
    text=extensions.read_text()
    marker='    const switchModelAction = createModelSwitchAction(ctx, state, {'
    if text.count(marker)!=1:raise ValueError('Unverified TUI model-switch dependency contract')
    text=text.replace(marker,marker+'\n        newSession: () => core.sessionSwitch.newSession(),')
    extensions.write_text(text)
    inject=target/'lib/types/dsh-adapter/inject-channel.js'
    text=inject.read_text()
    text="import { createHash } from 'node:crypto';\n"+text
    text=text.replace('return join(INJECT_DIR, `${sessionId}.sock`);', "return join(process.env.DSH_SOCKET_DIR, createHash('sha256').update(process.env.DSH_WATCHDOG_ROOT+'\\0'+sessionId).digest('hex').slice(0,32)+'.sock');")
    inject.write_text(text)
    host=target/'lib/types/dsh-adapter/host-dsh.js'
    text=host.read_text()
    marker='export function findHostDsh(env = process.env, platform = process.platform) {'
    if text.count(marker)!=1:raise ValueError('Unverified TUI host-discovery contract')
    text=text.replace(marker,marker+"\n    if(env.DSH_ISOLATED_TUI_ENTRY && env.DSH_WATCHDOG_RUNTIME)return {packageDir:join(env.DSH_WATCHDOG_RUNTIME,'node_modules','@deepseek-ai','dsh'),via:'isolated-runtime'};")
    host.write_text(text)
    (target/'.complete').write_text('1\n')
    return target/'bin/dsh-tui.js'


def prepare_launch(root, installed, source_home, endpoint):
    entry=copy_tui(root,source_home)
    copy_profiles(root,source_home)
    env=private_env(root,os.environ)
    env.update(DSH_HOME=str(root/'dsh'),DSH_TUI_DATA_DIR=str(root/'tui-data'),
               DSH_INSTALLED_ROOT=str(installed),DSH_INSTALL_HOME=str(source_home),
               DSH_ISOLATED_TUI_ENTRY=str(entry),DSH_ISOLATED_ENDPOINT=endpoint)
    env.update(DSH_TUI_NO_DELEGATE='1',DSH_LOCAL_MLX_SESSION='1',
               HARNESS_TOOL_ENV=str(installed/'tool-env'),VIRTUAL_ENV=str(installed/'tool-env/venv'),
               PLAYWRIGHT_BROWSERS_PATH=str(installed/'tool-env/browsers'))
    env['PATH']=os.pathsep.join([str(installed/'tool-env/bin'),str(installed/'tool-env/venv/bin'),
                 str(installed/'tool-env/node/node_modules/.bin'),str(source_home/'.local/bin'),env.get('PATH','')])
    (root/'tui-data').mkdir(exist_ok=True)
    onboarding=root/'tui-data/onboarding.json'
    if not onboarding.exists():onboarding.write_text(json.dumps({'completed':True,'version':1})+'\n')
    git=subprocess.run(['git','rev-parse','--show-toplevel'],capture_output=True,text=True)
    workspace=Path(git.stdout.strip()) if git.returncode==0 else Path.cwd()
    sockets=workspace/'.s';sockets.mkdir(mode=0o700,exist_ok=True)
    if len(os.fsencode(str(sockets/('0'*32+'.sock'))))>=104:
        raise ValueError('Workspace path too long for private macOS injection sockets')
    env['DSH_SOCKET_DIR']=str(sockets)
    return env


def configure_profiles(root, installed, endpoint, env):
    # Run a private generator; never mutate installed configuration/preferences.
    source=(installed/'configure.mjs').read_text()
    source=source.replace("path.join(home, '.dsh/profiles/dsh-tui/cordis.patch.yml')", "path.join(process.env.DSH_HOME, 'profiles/dsh-tui/cordis.patch.yml')")
    source=source.replace("path.join(home, '.dsh-tui/model.json')", "path.join(process.env.DSH_TUI_DATA_DIR, 'model.json')")
    source=source.replace("path.join(home, '.dsh-tui/model-recents.json')", "path.join(process.env.DSH_TUI_DATA_DIR, 'model-recents.json')")
    source=source.replace("'http://127.0.0.1:8090/v1'",json.dumps(endpoint+'/v1'))
    # Relative imports resolve against a private directory with immutable code inputs.
    work=root/'generator';work.mkdir(exist_ok=True)
    for name in ['runtime','tool-env']:
        link=work/name
        if not link.exists():link.symlink_to(installed/name,target_is_directory=True)
    link=work/'configure-context.mjs'
    if not link.exists():link.symlink_to(installed/'configure-context.mjs')
    (work/'configure.mjs').write_text(source)
    subprocess.run(['node',str(work/'configure.mjs')],env=env,check=True,stdout=subprocess.DEVNULL)


def unused_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0))
        return sock.getsockname()[1]


def prepare_worker(root, installed, backend_port, env):
    source=installed/'local-mlx'
    root.mkdir(parents=True,exist_ok=True)
    for file in source.iterdir():
        if file.is_file() and file.suffix in ('.py','.json'):
            shutil.copyfile(file,root/file.name)
    # Only immutable interpreters, executables and validated model overlays.
    for name in ['venv','venv-0.7.1rc1','venv-0.7.1.dev1','mtplx-venv','video-venv','mlx-serve',
                 'glm6-production','glm-rc1-production']:
        if (source/name).exists() and not (root/name).exists():
            (root/name).symlink_to((source/name).resolve(),target_is_directory=True)
    router=root/'router.py'
    text=router.read_text()
    text=re.sub(r'\b8092\b',str(backend_port),text)
    text=text.replace('(manager.selection_worker, manager.watch_dsh_picker, manager.watch_models)', '(manager.selection_worker,)')
    # No picker/preference state is consulted by a model/conversation worker.
    text=text.replace("pref = HOME / '.dsh-tui/model.json'", "pref = HERE / 'private-model-selection.json'")
    text=text.replace("(HOME / '.dsh-tui/model.json')", "(HERE / 'private-model-selection.json')")
    text=text.replace("'--ssd-session-cache', 'on'", "'--ssd-session-cache-dir', str(HERE / 'mtplx-cache'), '--ssd-session-cache', 'on'")
    text=text.replace("'--prefix-cache-disk', '64GB'", "'--prefix-cache-disk', 'off'")
    text=text.replace("'models': len(m.profiles)})", "'models': len(m.profiles), 'runtimeRoot': str(HERE), 'routerPID': os.getpid()})")
    router.write_text(text)
    video=root/'video_server.py'
    video.write_text(video.read_text().replace("Path.home() / 'Videos/DeepSeek'",'Path('+repr(str(root/'video-output'))+')'))
    subprocess.run([sys.executable,str(root/'configure.py')],env=env,check=True,stdout=subprocess.DEVNULL)


class Worker:
    def __init__(self,root,installed,session,model):
        self.root=root
        self.session=session
        self.model=model
        self.port=unused_port()
        self.backend_port=unused_port()
        self.env=private_env(root,os.environ)
        prepare_worker(root,installed,self.backend_port,self.env)
        self.log=(root/'router.log').open('ab',buffering=0)
        self.process=subprocess.Popen([sys.executable,str(root/'router.py'),'--owner',str(os.getpid()),
              '--port',str(self.port),'--compat-port','0','--no-preload'],env=self.env,stdout=self.log,stderr=subprocess.STDOUT)
        (root/'identity.json').write_text(json.dumps({'session':session,'model':model,'pid':self.process.pid,
              'routerPort':self.port,'backendPort':self.backend_port,'root':str(root)},indent=2)+'\n')
        while True:
            if self.process.poll() is not None:raise RuntimeError('Private router failed: '+str(root/'router.log'))
            try:
                conn=http.client.HTTPConnection('127.0.0.1',self.port,timeout=1)
                conn.request('GET','/status');response=conn.getresponse();body=response.read();conn.close()
                if response.status==200:
                    identity=json.loads(body)
                    if identity.get('runtimeRoot')!=str(root) or identity.get('routerPID')!=self.process.pid:
                        self.close();raise RuntimeError('Private router port belongs to another runtime')
                    break
            except OSError:time.sleep(.1)

    def close(self):
        if self.process.poll() is None:self.process.terminate()
        self.process.wait()
        self.log.close()


class Gateway:
    def __init__(self,root,installed):
        self.root=root;self.installed=installed;self.workers={};self.lock=threading.Lock()
        self.inference_lock=threading.Lock();self.active=None

    def worker(self,session,model):
        if not isinstance(session,str) or not session or len(session)>1024:raise ValueError('Missing native session identity')
        if not isinstance(model,str) or not model:raise ValueError('Missing model identity')
        key=digest(json.dumps([session,model]))
        with self.lock:
            if self.active is not None and self.active!=key:
                self.workers.pop(self.active).close()
                self.active=None
            if key not in self.workers:
                self.workers[key]=Worker(self.root/'routes'/key,self.installed,session,model)
            self.active=key
            return self.workers[key]

    def close(self):
        for worker in self.workers.values():worker.close()


def serve_gateway(root,installed,ready):
    gateway=Gateway(root,installed)
    class Handler(BaseHTTPRequestHandler):
        protocol_version='HTTP/1.1'
        def log_message(self,*args):pass
        def reply(self,status,data):
            body=json.dumps(data).encode();self.send_response(status)
            self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)))
            self.end_headers();self.wfile.write(body)
        def do_GET(self):
            if self.path=='/status':self.reply(200,{'root':str(root),'pid':os.getpid()})
            elif self.path=='/v1/models':
                profiles=json.loads((installed/'local-mlx/profiles.json').read_text())
                self.reply(200,{'object':'list','data':[{'id':str(Path(p).relative_to(Path.home()/'models')),'object':'model'} for p in profiles]})
            else:self.reply(404,{'error':{'message':'Unknown private gateway route'}})
        def do_POST(self):
            conn=None
            started=False
            owned=False
            try:
                length=int(self.headers.get('Content-Length','0'))
                if not 0<length<=64*1024*1024:raise ValueError('Invalid request length')
                body=self.rfile.read(length);data=json.loads(body)
                gateway.inference_lock.acquire();owned=True
                worker=gateway.worker(self.headers.get('X-DSH-Session'),data.get('model'))
                conn=http.client.HTTPConnection('127.0.0.1',worker.port,timeout=None)
                conn.request('POST',self.path,body,{'Content-Type':'application/json',
                    'X-DSH-Purpose':self.headers.get('X-DSH-Purpose','inference')})
                response=conn.getresponse()
                self.send_response(response.status);self.send_header('Content-Type',response.getheader('Content-Type','application/json'))
                self.send_header('Connection','close');self.end_headers();self.close_connection=True;started=True
                while True:
                    chunk=response.read1(65536)
                    if not chunk:break
                    self.wfile.write(chunk);self.wfile.flush()
            except Exception as error:
                if not started:self.reply(500,{'error':{'message':str(error)}})
            finally:
                if conn:conn.close()
                if owned:gateway.inference_lock.release()
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    server.daemon_threads=True
    ready.write_text(json.dumps({'port':server.server_port,'pid':os.getpid(),'root':str(root)})+'\n')
    def stop(*_):threading.Thread(target=server.shutdown,daemon=True).start()
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    owner=os.getppid()
    def watch_owner():
        while os.getppid()==owner:time.sleep(.5)
        stop()
    threading.Thread(target=watch_owner,daemon=True).start()
    try:server.serve_forever()
    finally:gateway.close();server.server_close()


if __name__=='__main__':
    if len(sys.argv)==5 and sys.argv[1]=='gateway':serve_gateway(Path(sys.argv[2]),Path(sys.argv[3]),Path(sys.argv[4]))
    else:raise SystemExit('Expected gateway ROOT INSTALLED READY')

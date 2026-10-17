"""Exactly one uncached 16,384-token chat request; preload is not inference."""
import fcntl
import hashlib
from importlib.metadata import version
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.request
from urllib.parse import quote

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / '.tmp/qwen-rc1-16k-20261017'
INSTALLED = Path.home() / '.local/share/deepseek-harness/local-mlx'
NAME = 'mlx-community/Qwen3.8-Flash-Next-oQ8e-mtp'
MODEL = Path.home() / 'models' / NAME
PORT = 18092
BASE = f'http://127.0.0.1:{PORT}'
assert version('omlx') == '0.7.1rc1'
OUT.mkdir(parents=True, exist_ok=True)
lock = (INSTALLED / 'session.lock').open('a')
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
for port in (8090,8092,PORT):
    with socket.socket() as check:
        if check.connect_ex(('127.0.0.1',port)) == 0:
            sys.exit(f'Existing model listener at {port}; refusing concurrent benchmark')
# No global route, picker or runtime configuration is changed.
profile = json.loads((INSTALLED / 'profiles.json').read_text())[str(MODEL)]
profile.update(is_pinned=False, is_default=True, model_alias=None)
state = OUT / 'state'
if state.exists():
    sys.exit('This benchmark state already exists; refusing a second inference')
state.mkdir()
active = OUT / 'active-model'
active.mkdir(exist_ok=True)
if not (active / MODEL.name).exists():
    (active / MODEL.name).symlink_to(MODEL, target_is_directory=True)
settings = {'version':'1.0',
 'server':{'host':'127.0.0.1','port':PORT,'log_level':'info','burst_decode_mode':'aggressive'},
 'model':{'model_dirs':[str(active)],'model_dir':str(active),'model_fallback':False},
 'memory':{'prefill_memory_guard':True,'memory_guard_tier':'custom','memory_guard_custom_ceiling_gb':112.0},
 'scheduler':{'max_concurrent_requests':1},
 'cache':{'enabled':True,'ssd_cache_dir':str(state / 'cache'),'ssd_cache_max_size':'8GB','hot_cache_max_size':'2GB'},
 'auth':{'skip_api_key_verification':True,'allow_unauthenticated_inference':True}}
(state / 'settings.json').write_text(json.dumps(settings,indent=2))
(state / 'model_settings.json').write_text(json.dumps({'version':1,'models':{MODEL.name:profile}},indent=2))
# Tokenization is CPU-only and does not count as a generation request.
from transformers import AutoTokenizer
tokenizer = AutoTokenizer.from_pretrained(str(MODEL),local_files_only=True)
head = 'Review the following code-audit notes. Explain the main invariant and a safe next diagnostic.\n'
unit = 'The water ledger records input, storage, transfer, and output. Verify each index and unit against the source before accepting a change.\n'
tail = '\nGive a careful technical answer with concrete checks.'
kwargs = {'tokenize':True,'add_generation_prompt':True,'enable_thinking':True,'reasoning_effort':'xhigh'}
def count(text):
    result = tokenizer.apply_chat_template([{'role':'user','content':text}],**kwargs)
    ids = result['input_ids'] if hasattr(result,'keys') else result
    if ids and isinstance(ids[0],list):
        ids = ids[0]
    return len(ids)
low, high = 0, 2000
while low < high:
    mid = (low+high+1)//2
    if count(head+unit*mid+tail) <= 16384:
        low = mid
    else:
        high = mid-1
text = head+unit*low+tail
for _ in range(100):
    n=count(text)
    if n == 16384:
        break
    if n > 16384:
        raise RuntimeError(f'Prompt overshot target: {n}')
    text += ' x'
assert count(text) == 16384, count(text)
payload={'model':MODEL.name,'messages':[{'role':'user','content':text}],
 'max_tokens':128,'temperature':1.0,'top_p':.95,'top_k':20,'stream':True,
 'stream_options':{'include_usage':True},'chat_template_kwargs':{'enable_thinking':True,'reasoning_effort':'xhigh'}}
(OUT / 'request.json').write_text(json.dumps(payload))
report={'runtime':version('omlx'),'mlx':version('mlx'),'model':NAME,'prompt_tokens_expected':16384,
 'inference_requests':0,'output_cap':128,'profile':profile,'cache':'fresh empty cache',
 'notes':'Native rc1 scheduler; prefill chunk 8192, 60% expert residency, native KV and adaptive MTP<=3; global dev1 unchanged.'}
(OUT / 'result.json').write_text(json.dumps(report,indent=2))
env={k:v for k,v in os.environ.items() if not k.startswith(('DSH_','OMLX_','GLM_ASYNC_'))}
env.update(PYTHONDONTWRITEBYTECODE='1',HF_HUB_OFFLINE='1',TOKENIZERS_PARALLELISM='false',
 TMPDIR=str(REPO / '.tmp'),XDG_CACHE_HOME=str(REPO / '.cache'),HF_HOME=str(OUT / 'hf-cache'),
 OMLX_MOE_EXPERT_OFFLOAD='1')
command=[sys.executable,str(REPO / 'tools/local-model-benchmark/serve_rc1.py'),'serve',
 '--base-path',str(state),'--model-dir',str(active),'--host','127.0.0.1','--port',str(PORT),
 '--memory-guard-gb','112','--hot-cache-max-size','2GB','--paged-ssd-cache-dir',str(state / 'cache')]
report['command']=command
server = None
try:
    with (OUT / 'server.log').open('wb') as log:
        server=subprocess.Popen(command,cwd=REPO,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    (OUT / 'server.pid').write_text(str(server.pid))
    deadline=time.monotonic()+180
    while time.monotonic()<deadline:
        if server.poll() is not None:
            raise RuntimeError('rc1 server exited before readiness; see server.log')
        try:
            with urllib.request.urlopen(BASE+'/v1/models',timeout=2) as response:
                catalog=json.load(response)
            break
        except OSError:
            time.sleep(.5)
    else:
        raise RuntimeError('Server readiness deadline exceeded')
    print('rc1 server ready; preloading Qwen Flash without generation',flush=True)
    load_start=time.monotonic()
    req=urllib.request.Request(BASE+'/v1/models/'+quote(MODEL.name,safe='')+'/load',data=b'{}',headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=1800) as response:
        report['preload']=json.load(response)
    report['model_load_seconds']=time.monotonic()-load_start
    print('Model loaded; issuing the single 16384-token prompt',flush=True)
    report['inference_requests']=1
    (OUT / 'result.json').write_text(json.dumps(report,indent=2))
    start=time.perf_counter();first=last=None;usage={};output={'content':'','reasoning_content':''}
    req=urllib.request.Request(BASE+'/v1/chat/completions',data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=7200) as response, (OUT / 'events.jsonl').open('w') as events:
        for line in response:
            if not line.startswith(b'data:'):
                continue
            raw=line[5:].strip()
            if raw==b'[DONE]':
                break
            event=json.loads(raw)
            events.write(json.dumps({'elapsed_s':time.perf_counter()-start,'event':event})+'\n')
            if event.get('error'):
                raise RuntimeError(event['error'])
            if event.get('usage'):
                usage=event['usage']
            for choice in event.get('choices',[]):
                delta=choice.get('delta',{})
                if delta.get('content') or delta.get('reasoning_content'):
                    last=time.perf_counter()
                    if first is None:
                        first=last
                for key in output:
                    output[key]+=delta.get(key) or ''
    if first is None:
        raise RuntimeError('No generated token received')
    report.update(status='complete',usage=usage,client_ttft_seconds=first-start,
                  client_elapsed_seconds=time.perf_counter()-start,
                  client_decode_tokens_per_second=(usage['completion_tokens']-1)/(last-first),
                  prompt_exact=usage.get('prompt_tokens')==16384)
    (OUT / 'output.json').write_text(json.dumps(output,indent=2))
    print(json.dumps({k:report[k] for k in ['status','usage','client_ttft_seconds','client_decode_tokens_per_second','prompt_exact']},indent=2),flush=True)
except BaseException as error:
    report.update(status='failed',error=repr(error))
    print(report['error'],flush=True)
    raise
finally:
    if server and server.poll() is None:
        server.terminate()
        try:
            server.wait(timeout=45)
        except subprocess.TimeoutExpired:
            server.kill();server.wait()
    report['server_stopped']=server is None or server.poll() is not None
    (OUT / 'result.json').write_text(json.dumps(report,indent=2))

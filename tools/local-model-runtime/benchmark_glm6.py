"""Matched long-context GLM6 runs with isolated state, original weights and rc1 runtime."""
import argparse
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request

REPO = Path(__file__).resolve().parents[2]
HERE = Path('/Users/4sanalyticsnmodelling/.local/share/deepseek-harness/local-mlx')
PYTHON = HERE/'venv-0.7.1rc1/bin/python'
NAME = 'GLM-5.3-Flash-MLX-6bit'
CAP = 114_000_000_000


def request(route, data=None, timeout=None):
    return urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8092'+route,
        data=json.dumps(data).encode() if data is not None else None,
        headers={'Content-Type': 'application/json'}), timeout=timeout)


def make_entry(out, width, chunk):
    source = (REPO/'audit/reviews/glm6-speed-20261017/sources/glm6_production.py').read_text()
    source = source.replace('HERE=Path(__file__).resolve().parent',
        f'HERE=Path({str(HERE)!r})\nsys.path.insert(0,str(HERE))')
    source = source.replace('state=HERE/STATE_NAME', f'state=Path({str(out)!r})')
    injection = f'''
sys.path.insert(0,{str(Path(__file__).parent)!r})
import glm6_lookahead as lookahead
lookahead.install(pipeline,width={width})
import atexit
def save_telemetry():
    caches=lookahead.CACHES
    (state/'telemetry.json').write_text(json.dumps(dict(lookahead=lookahead.STATS,
        overlap=pipeline.STATS,layers=[dict(capacity=c.capacity,total=c.n_experts,
        expert_bytes=c.expert_bytes,hits=c.hits,misses=c.misses,fetched_bytes=c.fetched_bytes)
        for c in caches]),indent=2))
signal_module=__import__('signal')
signal_module.signal(signal_module.SIGUSR1,lambda *args: save_telemetry())
def set_test_width(*args):
    command=json.loads((state/'width-control.json').read_text())
    value=command['width']
    if value not in (0,2,4): raise ValueError('Invalid benchmark width')
    lookahead.WIDTH=value
    temporary=state/'width-ack.tmp'
    temporary.write_text(json.dumps(dict(nonce=command['nonce'],width=lookahead.WIDTH)))
    temporary.replace(state/'width-ack.json')
signal_module.signal(signal_module.SIGUSR2,set_test_width)
atexit.register(save_telemetry)
'''
    # Baseline uses identical instrumentation with prefetch disabled.
    source = source.replace('original_apply=offload.apply_deepseek_v4_moe_expert_offload',
        injection+'\noriginal_apply=offload.apply_deepseek_v4_moe_expert_offload')
    source = source.replace('result=original_apply(model,*args,**kwargs)',
        'result=original_apply(model,*args,**kwargs)\n    lookahead.bind(model)')
    (out/'server.py').write_text(source)


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--name',required=True)
    ap.add_argument('--width',type=int,default=0)
    ap.add_argument('--tokens',type=int,default=16384)
    ap.add_argument('--chunk',type=int,default=5632)
    ap.add_argument('--output',type=int,default=128)
    ap.add_argument('--retrieval',action='store_true')
    ap.add_argument('--cache-source')
    ap.add_argument('--once',action='store_true')
    ap.add_argument('--paired-decode',action='store_true')
    args=ap.parse_args()
    args.paired_decode=args.paired_decode or args.name=='selected64'
    out=REPO/'audit/reviews/glm6-speed-20261017'/args.name
    out.mkdir(exist_ok=False)
    # The shared lock protects against existing sessions without writing outside the repo.
    lock=(HERE/'session.lock').open('r')
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    for port in (8090,8092):
        with socket.socket() as s:
            if s.connect_ex(('127.0.0.1',port))==0:
                raise RuntimeError('Existing inference listener; refusing interruption')
    sys.path.insert(0,str(HERE))
    from omlx.utils.proc_memory import get_phys_footprint,get_lifetime_max_phys_footprint,_RusageInfoV4,_proc_pid_rusage
    def disk(pid):
        info=_RusageInfoV4()
        if _proc_pid_rusage(pid,4,ctypes.byref(info))!=0:raise RuntimeError('disk stats unavailable')
        return int(info.ri_diskio_bytesread)
    profile=json.loads((HERE/'performance-overrides.json').read_text())[NAME]
    from glm6_profile import resolve_runtime,configure_environment
    target=Path('/Users/4sanalyticsnmodelling/models')/NAME
    overlay,_=resolve_runtime(target,profile,HERE)
    (out/'models').mkdir()
    (out/'models'/NAME).symlink_to(overlay,target_is_directory=True)
    if args.cache_source:
        cache_source=REPO/'audit/reviews/glm6-speed-20261017'/args.cache_source/'cache'
        if not cache_source.is_dir():raise ValueError('Missing source prefix cache')
        (out/'cache').symlink_to(cache_source,target_is_directory=True)
    settings=json.loads((HERE/'omlx-state-glm6-r35/settings.json').read_text())
    settings['model']={'model_dirs':[str(out/'models')],'model_dir':str(out/'models')}
    settings['cache']['ssd_cache_dir']=str(out/'cache')
    (out/'settings.json').write_text(json.dumps(settings,indent=2))
    (out/'model_settings.json').write_text(json.dumps({'version':1,'models':{NAME:profile}},indent=2))
    make_entry(out,args.width,args.chunk)
    # Use the same coding corpus and sampler as the historical production benchmark.
    payload=json.loads((HERE/'glm6-r35-strategy-base-20261015/request.json').read_text())
    corpus=payload['messages'][0]['content']
    from transformers import AutoTokenizer
    tokenizer=AutoTokenizer.from_pretrained(str(overlay),local_files_only=True,trust_remote_code=False)
    encoded=tokenizer.encode(corpus,add_special_tokens=False)
    body_tokens=args.tokens-256
    repeated=encoded*((args.tokens//len(encoded))+2)
    for attempt in range(12):
        content=tokenizer.decode(repeated[:body_tokens])
        if args.retrieval or args.tokens>32768 or args.tokens==16384:
            key='OTTAWA_REVIEW_CODE=79146283'
            middle=len(tokenizer.decode(repeated[:8192])) if args.tokens==16384 else len(content)//2
            content=content[:middle]+'\n'+key+'\n'+content[middle:]
        if args.retrieval:
            content+='\nReturn only the eight digits assigned to OTTAWA_REVIEW_CODE. Do not explain.'
        else:
            content+='\nReview this code and design a streaming CSV validation library with typed errors, duplicate-key detection and required-column validation. Explain the implementation and provide Python code.'
        payload['messages']=[{'role':'user','content':content}]
        if args.tokens!=16384:break
        rendered=tokenizer.apply_chat_template(payload['messages'],tokenize=False,
            add_generation_prompt=True,**payload['chat_template_kwargs'])
        actual=len(tokenizer.encode(rendered,add_special_tokens=False))
        if 0<args.tokens-actual<=8:
            # Trimming a BPE token can change a boundary by two tokens. Harmless
            # trailing whitespace fills the one-token gap without changing the task.
            for padding in (' ','  ','\n ','\t','\n\n '):
                padded=content+padding
                text=tokenizer.apply_chat_template([{'role':'user','content':padded}],
                    tokenize=False,add_generation_prompt=True,**payload['chat_template_kwargs'])
                if len(tokenizer.encode(text,add_special_tokens=False))==args.tokens:
                    content=padded;payload['messages'][0]['content']=content;actual=args.tokens
                    break
        if actual==args.tokens:break
        body_tokens+=args.tokens-actual
    else:raise ValueError('Could not construct exact16K prompt')
    payload['max_tokens']=args.output
    payload['seed']=20261014
    (out/'request.json').write_text(json.dumps(payload,indent=2))
    env={k:v for k,v in os.environ.items() if not k.startswith(('DSH_','OMLX_','GLM_ASYNC_'))}
    configure_environment(env,target,profile,target.parent)
    env.update(HF_HUB_OFFLINE='1',TOKENIZERS_PARALLELISM='false',PYTHONDONTWRITEBYTECODE='1',
        OMLX_MOE_EXPERT_OFFLOAD='1',OMLX_MOE_OFFLOAD_IO_WORKERS='12',OMLX_MOE_OFFLOAD_OVERLAP='1',
        TMPDIR=str(REPO/'.tmp/glm6-speed'),XDG_CACHE_HOME=str(REPO/'.cache'))
    command=[str(PYTHON),'-B',str(out/'server.py'),str(args.chunk),'serve','--base-path',str(out),
        '--model-dir',str(out/'models'),'--host','127.0.0.1','--port','8092',
        '--memory-guard-gb',str(CAP/1024**3),'--hot-cache-max-size','2GB','--paged-ssd-cache-dir',str(out/'cache')]
    report=dict(arguments=vars(args),command=command,started=time.time(),samples=[],peak_physical_bytes=0,
        prompt_sha256=hashlib.sha256(content.encode()).hexdigest(),profile=profile,
        terminal_config_sha256=hashlib.sha256(Path('/Users/4sanalyticsnmodelling/.wezterm.lua').read_bytes()).hexdigest(),
        swap_at_start=subprocess.check_output(['sysctl','vm.swapusage'],text=True).strip(),
        source_shards={p.name:[p.stat().st_size,p.stat().st_mtime_ns] for p in target.glob('*.safetensors')})
    def save():
        tmp=out/'result.tmp';tmp.write_text(json.dumps(report,indent=2));tmp.replace(out/'result.json')
    proc=None;done=threading.Event()
    def monitor():
        while not done.wait(.25):
            if proc.poll() is not None:return
            size=get_phys_footprint(proc.pid)
            report['peak_physical_bytes']=max(report['peak_physical_bytes'],size,get_lifetime_max_phys_footprint(proc.pid))
            (out/'progress.json').write_text(json.dumps(dict(pid=proc.pid,physical_bytes=size,peak=report['peak_physical_bytes'],elapsed=time.time()-report['started'])))
            if size>=CAP:
                report['memory_abort_bytes']=size
                os.killpg(proc.pid,signal.SIGTERM)
                return
    try:
        with (out/'server.log').open('w') as log:
            proc=subprocess.Popen(command,env=env,stdout=log,stderr=log,start_new_session=True)
        report['pid']=proc.pid;save()
        threading.Thread(target=monitor,daemon=True).start()
        while True:
            if proc.poll() is not None:raise RuntimeError(f'Server exited {proc.returncode}')
            try:
                with request('/v1/models',timeout=1):break
            except OSError:time.sleep(.5)
        with request('/admin/api/models/'+NAME+'/load',{}):pass
        kinds=('prefix_restore',) if args.cache_source else ('fresh','warm')
        if args.once:kinds=kinds[:1]
        if args.paired_decode:kinds+=('control_a','candidate_a','candidate_b','control_b')
        for kind in kinds:
            test_width=args.width
            acknowledgement=None
            if kind.startswith(('control_','candidate_')):
                test_width=0 if kind.startswith('control_') else args.width
                nonce=time.time_ns()
                (out/'width-control.json').write_text(json.dumps(dict(width=test_width,nonce=nonce)))
                os.kill(proc.pid,signal.SIGUSR2)
                while True:
                    if proc.poll() is not None:raise RuntimeError('Backend exited during width switch')
                    try:acknowledgement=json.loads((out/'width-ack.json').read_text())
                    except (FileNotFoundError,json.JSONDecodeError):acknowledgement={}
                    if acknowledgement==dict(nonce=nonce,width=test_width):break
                    time.sleep(.05)
                payload['max_tokens']=128
            start=time.monotonic();first=last=None;usage={};output={'content':'','reasoning_content':''};before=disk(proc.pid)
            finished=False;finish_reasons=[]
            with request('/v1/chat/completions',payload) as response:
                for line in response:
                    if not line.startswith(b'data: '):continue
                    raw=line[6:].strip()
                    if raw==b'[DONE]':
                        finished=True
                        break
                    event=json.loads(raw)
                    if event.get('error'):raise RuntimeError(event['error'])
                    if event.get('usage'):usage=event['usage']
                    for choice in event.get('choices',[]):
                        if choice.get('finish_reason'):finish_reasons.append(choice['finish_reason'])
                        delta=choice.get('delta',{})
                        if delta.get('content') or delta.get('reasoning_content'):
                            first=first or time.monotonic();last=time.monotonic()
                        for key in output:output[key]+=delta.get(key) or ''
            if not usage.get('completion_tokens'):raise RuntimeError('No completion tokens')
            if args.tokens==16384 and usage['prompt_tokens']!=16384:
                raise RuntimeError('Server prompt was not exactly16K')
            if not finished or not finish_reasons:raise RuntimeError('Truncated completion stream')
            if not args.retrieval and usage['completion_tokens']!=payload['max_tokens']:
                raise RuntimeError('Throughput completion ended before requested token count')
            cached=usage.get('prompt_tokens_details',{}).get('cached_tokens',0)
            if kind=='fresh' and cached!=0:raise RuntimeError('Fresh prompt unexpectedly cached')
            row=dict(kind=kind,test_width=test_width,elapsed_seconds=time.monotonic()-start,ttft_seconds=first-start if first else None,
                width_ack=acknowledgement,
                usage=usage,disk_read_bytes=disk(proc.pid)-before,finish_reasons=finish_reasons,
                client_decode_tokens_per_second=(usage['completion_tokens']-1)/(last-first) if last and first and last>first else None,
                full_prefix_restored=cached==usage['prompt_tokens']-2 if kind=='warm' or kind.startswith(('control_','candidate_')) else None,
                output_sha256=hashlib.sha256(json.dumps(output,sort_keys=True).encode()).hexdigest())
            if args.retrieval:row['retrieval_pass']=output['content'].strip()=='79146283'
            (out/f'output-{kind}.json').write_text(json.dumps(output,indent=2))
            report['samples'].append(row);save();print(json.dumps(row),flush=True)
            if (kind=='warm' or kind.startswith(('control_','candidate_'))) and not row['full_prefix_restored']:
                report['partial_warm_prefix']=True
            if args.retrieval and not row['retrieval_pass']:
                raise RuntimeError('Long-context retrieval answer incorrect')
            os.kill(proc.pid,signal.SIGUSR1)
            time.sleep(.25)
            if (out/'telemetry.json').exists():
                (out/f'telemetry-{kind}.json').write_bytes((out/'telemetry.json').read_bytes())
        report['complete']=True
    except BaseException as error:
        report['error']=repr(error)
        raise
    finally:
        done.set()
        if proc is not None and proc.poll() is None:
            os.killpg(proc.pid,signal.SIGTERM)
            try:proc.wait(timeout=30)
            except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
        report['finished']=time.time()
        report['swap_at_end']=subprocess.check_output(['sysctl','vm.swapusage'],text=True).strip()
        report['source_shards_unchanged']=report['source_shards']=={p.name:[p.stat().st_size,p.stat().st_mtime_ns] for p in target.glob('*.safetensors')}
        save()


if __name__=='__main__':main()

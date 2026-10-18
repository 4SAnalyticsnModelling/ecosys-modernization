"""Serial qualification; progress persists and healthy runs have no time limit."""
import json
import os
from pathlib import Path
import subprocess
import time

REPO=Path(__file__).resolve().parents[2]
OUT=REPO/'audit/reviews/glm6-speed-20261017'
PYTHON='/Users/4sanalyticsnmodelling/.local/share/deepseek-harness/local-mlx/venv-0.7.1rc1/bin/python'
TOOLS=Path(__file__).parent
state=dict(pid=os.getpid(),stage='waiting for baseline',results={})


def save(stage):
    state['stage']=stage
    tmp=OUT/'suite-state.tmp';tmp.write_text(json.dumps(state,indent=2));tmp.replace(OUT/'suite-state.json')
    print(stage,flush=True)


def run(name,*flags):
    save(name)
    with (OUT/(name+'-driver.log')).open('w') as log:
        p=subprocess.run([PYTHON,'-B',str(TOOLS/'benchmark_glm6.py'),'--name',name,*map(str,flags)],stdout=log,stderr=log,cwd=REPO)
    result=json.loads((OUT/name/'result.json').read_text()) if (OUT/name/'result.json').exists() else {'error':'runner failed before receipt'}
    state['results'][name]=dict(returncode=p.returncode,complete=result.get('complete',False),error=result.get('error'))
    save(name+' finished')
    return result


def qualified(base,candidate):
    if not candidate.get('complete'):return False
    for a,b in zip(base['samples'],candidate['samples'],strict=True):
        if a['usage']['prompt_tokens']!=b['usage']['prompt_tokens']:return False
        if a['usage']['prompt_tokens_details']!=b['usage']['prompt_tokens_details']:return False
        if a['output_sha256']!=b['output_sha256']:return False
        if b['usage']['generation_tokens_per_second']<=a['usage']['generation_tokens_per_second']:return False
    return True


def main():
    save('waiting for baseline')
    while True:
        try:base=json.loads((OUT/'base32/result.json').read_text())
        except (FileNotFoundError,json.JSONDecodeError):base={}
        if base.get('finished'):break
        time.sleep(2)
    if not base.get('complete'):raise RuntimeError('Baseline failed')
    save('cache parity and failure tests')
    with (OUT/'parity-check.log').open('w') as log:
        subprocess.run([PYTHON,'-B',str(TOOLS/'check_glm6_lookahead.py')],stdout=log,stderr=log,check=True)
    candidate=run('lookahead2-32','--tokens',32768,'--width',2)
    width=2;name='lookahead2-32'
    if not qualified(base,candidate):
        candidate=run('lookahead4-32','--tokens',32768,'--width',4)
        width=4;name='lookahead4-32'
    if not qualified(base,candidate):
        width=0;name='base32'
    state.update(selected_width=width,selected_candidate=name)
    # Check the suggested larger prefill chunk without changing any memory ceiling.
    run('chunk8192-32','--tokens',32768,'--width',width,'--chunk',8192,'--once')
    result=run('selected64','--tokens',65536,'--width',width,'--output',512,'--paired-decode')
    if not result.get('complete'):raise RuntimeError('64K context validation failed')
    retrieval=run('retrieval64','--tokens',65536,'--width',width,'--output',512,
        '--retrieval','--cache-source','selected64','--once')
    if not retrieval.get('complete'):raise RuntimeError('Retrieval validation failed')
    save('qualification complete; production deployment awaits result review')


if __name__=='__main__':
    try:main()
    except BaseException as error:
        state['error']=repr(error);save('qualification failed');raise

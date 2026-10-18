"""User-scoped16K-only comparison; all inference keeps maximum thinking."""
import json
import os
from pathlib import Path
import subprocess

REPO=Path(__file__).resolve().parents[2]
OUT=REPO/'audit/reviews/glm6-speed-20261017'
PYTHON='/Users/4sanalyticsnmodelling/.local/share/deepseek-harness/local-mlx/venv-0.7.1rc1/bin/python'
state=dict(pid=os.getpid(),stage='starting16K-only suite',results={})


def save(stage):
    state['stage']=stage
    p=OUT/'suite16-state.tmp';p.write_text(json.dumps(state,indent=2));p.replace(OUT/'suite16-state.json')
    print(stage,flush=True)


def run(name,*flags):
    save(name)
    with (OUT/(name+'-driver.log')).open('w') as log:
        result=subprocess.run([PYTHON,'-B',str(Path(__file__).with_name('benchmark_glm6.py')),
            '--name',name,'--tokens','16384',*map(str,flags)],stdout=log,stderr=log,cwd=REPO)
    receipt=json.loads((OUT/name/'result.json').read_text()) if (OUT/name/'result.json').exists() else {'error':'No run receipt'}
    state['results'][name]=dict(returncode=result.returncode,complete=receipt.get('complete',False),error=receipt.get('error'))
    save(name+' finished')
    if result.returncode or not receipt.get('complete'):raise RuntimeError('Failed16K test: '+name)
    return receipt


def same_outputs(a,b):
    return all(x['output_sha256']==y['output_sha256'] and x['usage']['prompt_tokens_details']==y['usage']['prompt_tokens_details']
        for x,y in zip(a['samples'],b['samples'],strict=True))


def main():
    base=run('base16','--width',0)
    candidate=run('lookahead2-16','--width',2)
    if not same_outputs(base,candidate):raise RuntimeError('Prefetch changed sampled output or cache coverage')
    useful=all(b['usage']['generation_tokens_per_second']>a['usage']['generation_tokens_per_second']
        for a,b in zip(base['samples'],candidate['samples'],strict=True))
    width=2 if useful else 0
    best='lookahead2-16' if useful else 'base16';chunk=5632
    larger=run('chunk8192-16','--width',width,'--chunk',8192)
    if not same_outputs(base,larger):raise RuntimeError('Larger chunk changed sampled output or cache coverage')
    comparison=candidate if useful else base
    if larger['samples'][0]['usage']['prompt_tokens_per_second']>1.05*comparison['samples'][0]['usage']['prompt_tokens_per_second']:
        best='chunk8192-16';chunk=8192
    state.update(selected_width=width,selected_candidate=best,selected_chunk=chunk)
    save('selected16K configuration')
    run('retrieval16','--width',width,'--chunk',chunk,'--output',512,'--retrieval','--cache-source',best,'--once')
    save('16K qualification complete; final review pending')


if __name__=='__main__':
    try:main()
    except BaseException as error:
        state['error']=repr(error);save('16K qualification failed');raise

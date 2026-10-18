"""Qualify the larger prefill chunk at64K after the serial baseline suite."""
import json
import os
from pathlib import Path
import subprocess
import time

REPO=Path(__file__).resolve().parents[2]
OUT=REPO/'audit/reviews/glm6-speed-20261017'
PYTHON='/Users/4sanalyticsnmodelling/.local/share/deepseek-harness/local-mlx/venv-0.7.1rc1/bin/python'
state=dict(pid=os.getpid(),stage='waiting for64K baseline suite')


def save(stage):
    state['stage']=stage
    temp=OUT/'extension-state.tmp';temp.write_text(json.dumps(state,indent=2));temp.replace(OUT/'extension-state.json')
    print(stage,flush=True)


def run(name,*flags):
    save(name)
    with (OUT/(name+'-driver.log')).open('w') as log:
        result=subprocess.run([PYTHON,'-B',str(Path(__file__).with_name('benchmark_glm6.py')),
            '--name',name,*map(str,flags)],stdout=log,stderr=log,check=True)
    return json.loads((OUT/name/'result.json').read_text())


def main():
    save(state['stage'])
    while True:
        suite=json.loads((OUT/'suite-state.json').read_text())
        if suite['stage']=='qualification failed':raise RuntimeError('Prior suite failed; inspect before extension')
        if suite['stage'].startswith('qualification complete'):break
        time.sleep(2)
    width=suite['selected_width']
    if not width:raise RuntimeError('No useful decode optimization selected')
    result=run('selected64-c8192','--tokens',65536,'--width',width,'--chunk',8192,'--output',128,'--paired-decode')
    if not result.get('complete'):raise RuntimeError('Larger chunk failed64K')
    result=run('retrieval64-c8192','--tokens',65536,'--width',width,'--chunk',8192,'--output',512,
        '--retrieval','--cache-source','selected64-c8192','--once')
    if not result.get('complete'):raise RuntimeError('Larger chunk retrieval failed')
    save('larger chunk qualification complete; final comparison pending')


if __name__=='__main__':
    try:main()
    except BaseException as error:
        state['error']=repr(error);save('larger chunk qualification failed');raise

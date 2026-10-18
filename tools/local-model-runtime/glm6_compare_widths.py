"""Compare production lookahead2 against4 at16K, retaining complete receipts."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

REPO=Path(__file__).resolve().parents[2]
OUT=REPO/'audit/reviews/glm6-speed-20261017'
PYTHON='/Users/4sanalyticsnmodelling/.local/share/deepseek-harness/local-mlx/venv-0.7.1rc1/bin/python'


def main():
    state=dict(pid=os.getpid(),started=time.time(),scope='16384 prompt tokens only',results={})
    path=OUT/'width2-vs4-state.json'
    def save():path.write_text(json.dumps(state,indent=2)+'\n')
    for width in (2,4):
        name=f'compare-width{width}-16'
        state['stage']=name;save()
        command=[PYTHON,'-B',str(Path(__file__).with_name('benchmark_glm6.py')),
            '--name',name,'--tokens','16384','--width',str(width),'--chunk','8192','--output','128']
        with (OUT/f'{name}-driver.log').open('w') as log:
            result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
        receipt=json.loads((OUT/name/'result.json').read_text())
        if result.returncode or not receipt.get('complete') or receipt.get('error') or receipt.get('memory_abort_bytes') or receipt.get('partial_warm_prefix') or not receipt.get('source_shards_unchanged'):
            state.update(stage='failed',error=name);save();raise RuntimeError('Incomplete or failed comparison: '+name)
        state['results'][str(width)]=receipt;save()
    a,b=(state['results'][str(w)] for w in (2,4))
    for key in ('prompt_sha256','terminal_config_sha256','source_shards'):
        if a[key]!=b[key]:raise ValueError('Mismatched '+key)
    for x,y in zip(a['samples'],b['samples'],strict=True):
        for key in ('kind','output_sha256'):
            if x[key]!=y[key]:raise ValueError('Mismatched sample '+key)
        for key in ('prompt_tokens','completion_tokens','prompt_tokens_details'):
            if x['usage'][key]!=y['usage'][key]:raise ValueError('Mismatched usage '+key)
    summary={}
    for width,r in ((2,a),(4,b)):
        fresh,warm=r['samples']
        before=json.loads((OUT/f'compare-width{width}-16/telemetry-fresh.json').read_text())['lookahead']
        after=json.loads((OUT/f'compare-width{width}-16/telemetry-warm.json').read_text())['lookahead']
        delta={k:after[k]-before[k] for k in after}
        summary[str(width)]=dict(fresh_seconds=fresh['elapsed_seconds'],
            prefill_tps=fresh['usage']['prompt_tokens_per_second'],
            fresh_decode_tps=fresh['usage']['generation_tokens_per_second'],
            warm_decode_tps=warm['usage']['generation_tokens_per_second'],
            warm_disk_read_bytes=warm['disk_read_bytes'],warm_lookahead=delta,
            peak_physical_bytes=r['peak_physical_bytes'])
    state.update(stage='complete',summary=summary,finished=time.time(),
        implementation_sha256=hashlib.sha256(Path(__file__).with_name('glm6_lookahead.py').read_bytes()).hexdigest())
    save();print(json.dumps(summary,indent=2))


if __name__=='__main__':main()

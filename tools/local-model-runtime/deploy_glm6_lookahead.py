"""Promote a measured GLM6 lookahead width, preserving a byte-for-byte rollback."""
import argparse
import ast
import fcntl
import hashlib
import json
from pathlib import Path
import socket

REPO=Path(__file__).resolve().parents[2]
HERE=Path('/Users/4sanalyticsnmodelling/.local/share/deepseek-harness/local-mlx')
OUT=REPO/'audit/reviews/glm6-speed-20261017'
NAME='GLM-5.3-Flash-MLX-6bit'


def replace_once(text, old, new):
    if text.count(old)!=1:raise ValueError('Installed GLM6 source changed: '+old)
    return text.replace(old,new,1)


def entry_source(source):
    source=replace_once(source,'original_apply=offload.apply_deepseek_v4_moe_expert_offload',
        "import glm6_lookahead as decode_prefetch\n"
        "prefetch_width=profile.get('glm6_decode_lookahead_width',0)\n"
        "if prefetch_width:\n    decode_prefetch.install(pipeline,width=prefetch_width)\n"
        'original_apply=offload.apply_deepseek_v4_moe_expert_offload')
    source=replace_once(source,'result=original_apply(model,*args,**kwargs)',
        'result=original_apply(model,*args,**kwargs)\n    if prefetch_width: decode_prefetch.bind(model)')
    source=replace_once(source,"            last=time.monotonic()",
        "            (state/'decode-prefetch.json').write_text(json.dumps(dict(width=prefetch_width,stats=decode_prefetch.STATS,staging=pipeline.STATS)))\n"
        "            last=time.monotonic()")
    source=source.replace('; decode lookahead disabled', '; bounded decode lookahead selected by qualified profile')
    ast.parse(source)
    return source


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--candidate',required=True);ap.add_argument('--width',type=int,choices=(0,2),required=True)
    ap.add_argument('--chunk',type=int,choices=(5632,8192),default=5632)
    ap.add_argument('--retrieval-run',default='retrieval16')
    args=ap.parse_args()
    baseline=json.loads((OUT/'base16/result.json').read_text())
    candidate=json.loads((OUT/args.candidate/'result.json').read_text())
    suite=json.loads((OUT/'suite16-state.json').read_text())
    if suite.get('selected_width')!=args.width or suite.get('selected_candidate')!=args.candidate:
        raise ValueError('Suite selection differs from proposed deployment')
    if not baseline.get('complete') or not candidate.get('complete'):raise ValueError('Incomplete comparison')
    if candidate['arguments']['width']!=args.width:raise ValueError('Candidate width mismatch')
    if candidate['arguments']['chunk']!=args.chunk or suite.get('selected_chunk')!=args.chunk:raise ValueError('Candidate chunk mismatch')
    if candidate.get('error') or candidate.get('memory_abort_bytes'):raise ValueError('Candidate failed')
    if not candidate['source_shards_unchanged']:raise ValueError('Checkpoint metadata changed')
    for a,b in zip(baseline['samples'],candidate['samples'],strict=True):
        if a['usage']['prompt_tokens']!=b['usage']['prompt_tokens']:raise ValueError('Prompt counts differ')
        if a['usage']['prompt_tokens_details']!=b['usage']['prompt_tokens_details']:raise ValueError('Cache coverage differs')
        if a['kind']=='warm' and b['usage']['prompt_tokens_details']['cached_tokens']!=b['usage']['prompt_tokens']-2:
            raise ValueError('Warm prefix was only partially restored')
        if a['output_sha256']!=b['output_sha256']:raise ValueError('Sampled outputs differ')
        if b['usage']['prompt_tokens']!=16384:raise ValueError('Candidate did not test exactly16K')
    if candidate['terminal_config_sha256']!=baseline['terminal_config_sha256']:
        raise ValueError('Terminal configuration changed between16K arms')
    if not (candidate['samples'][0]['elapsed_seconds']<.97*baseline['samples'][0]['elapsed_seconds']
            or candidate['samples'][1]['usage']['generation_tokens_per_second']>1.03*baseline['samples'][1]['usage']['generation_tokens_per_second']):
        raise ValueError('No useful measured speed improvement')
    if args.chunk==8192:
        control=json.loads((OUT/('lookahead2-16' if args.width else 'base16')/'result.json').read_text())
        treated=candidate
        a=control['samples'][0];b=treated['samples'][0]
        if control['prompt_sha256']!=treated['prompt_sha256'] or a['usage']['prompt_tokens']!=b['usage']['prompt_tokens']:
            raise ValueError('Larger chunk used a different prompt')
        if b['usage']['prompt_tokens_per_second']<1.05*a['usage']['prompt_tokens_per_second']:
            raise ValueError('Larger chunk prefill gain below 5%')
    for name in (args.retrieval_run,):
        result=json.loads((OUT/name/'result.json').read_text())
        if (not result.get('complete') or result.get('error') or result.get('memory_abort_bytes')
                or not result.get('source_shards_unchanged') or result.get('partial_warm_prefix')):
            raise ValueError('Unqualified16K retrieval receipt: '+name)
        if result['arguments']['width']!=args.width or result['arguments']['chunk']!=args.chunk:
            raise ValueError('Retrieval receipt used different runtime settings')
        if not result['samples'] or any(s['usage']['prompt_tokens']!=16384 for s in result['samples']):
            raise ValueError('Retrieval receipt did not test exactly16K')
        if name==args.retrieval_run and not all(s.get('retrieval_pass') for s in result['samples']):
            raise ValueError('Retrieval validation failed')
    if args.width:
        telemetry=json.loads((OUT/args.candidate/'telemetry-warm.json').read_text())['lookahead']
        if telemetry['predictions']<=0 or telemetry['useful_experts']<=0:raise ValueError('Prefetch did not execute')
    lock=(HERE/'session.lock').open('r')
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    for port in (8090,8092):
        with socket.socket() as sock:
            if sock.connect_ex(('127.0.0.1',port))==0:raise RuntimeError('Existing inference listener')
    originals={p:(HERE/p).read_bytes() for p in ('glm6_production.py','glm6_profile.py','performance-overrides.json','profiles.json','omlx-state-glm6-r35/model_settings.json')}
    previous_module=(HERE/'glm6_lookahead.py').read_bytes() if (HERE/'glm6_lookahead.py').exists() else None
    expected=json.loads((OUT/'baseline-hashes.json').read_text())
    for name in ('glm6_production.py','glm6_profile.py'):
        if hashlib.sha256(originals[name]).hexdigest()!=expected[name]:raise ValueError('Production source drift: '+name)
    backup=OUT/'deployment-backup';backup.mkdir(exist_ok=False)
    for name,data in originals.items():
        p=backup/name;p.parent.mkdir(exist_ok=True,parents=True);p.write_bytes(data)
    if previous_module is not None:(backup/'glm6_lookahead.py').write_bytes(previous_module)
    content={'glm6_production.py':entry_source(originals['glm6_production.py'].decode()),
             'glm6_profile.py':replace_once(originals['glm6_profile.py'].decode(),
                 'prefill_step_size=5632',f'prefill_step_size={args.chunk}'),
             'glm6_lookahead.py':(Path(__file__).parent/'glm6_lookahead.py').read_text()}
    for name in ('performance-overrides.json','profiles.json','omlx-state-glm6-r35/model_settings.json'):
        d=json.loads(originals[name]);models=d.get('models',d)
        matches=[p for key,p in models.items() if key==NAME or key.endswith('/'+NAME)]
        if len(matches)!=1:raise ValueError('Expected one GLM6 profile in '+name)
        p=matches[0];p['glm6_decode_lookahead_width']=args.width
        p['prefill_step_size']=args.chunk
        p['enable_thinking']=True
        p.setdefault('chat_template_kwargs',{})['reasoning_effort']='max'
        p['description']=p.get('description','').replace('Decode lookahead disabled.',f'Bounded decode lookahead width{args.width}, prefill{args.chunk}, qualified at16K with max thinking.')
        content[name]=json.dumps(d,indent=2)+'\n'
    try:
        for name,text in content.items():
            path=HERE/name;tmp=path.with_name(path.name+'.glm6-new');tmp.write_text(text);tmp.replace(path)
    except BaseException:
        for name,data in originals.items():(HERE/name).write_bytes(data)
        if previous_module is None:(HERE/'glm6_lookahead.py').unlink(missing_ok=True)
        else:(HERE/'glm6_lookahead.py').write_bytes(previous_module)
        raise
    receipt=dict(candidate=args.candidate,width=args.width,chunk=args.chunk,validated_prompt_tokens=16384,retrieval_run=args.retrieval_run,backup=str(backup),
        files={name:hashlib.sha256((HERE/name).read_bytes()).hexdigest() for name in content})
    (OUT/'deployment.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt,indent=2))


if __name__=='__main__':main()

#!/usr/bin/env python3
"""Explicitly authorized Qwen rc1 production promotion with versioned backups."""
import ast
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

REPO=Path(__file__).resolve().parents[2]
HERE=Path.home()/'.local/share/deepseek-harness/local-mlx'
NAME='mlx-community/Qwen3.8-Flash-Next-oQ8e-mtp'
BACKUP=REPO/'watchdog/rc1-production-backup'


def replace_once(text,old,new):
    if new in text:return text
    if text.count(old)!=1:raise RuntimeError('Unexpected installed source: '+old[:90])
    return text.replace(old,new,1)


def main():
    BACKUP.mkdir(parents=True,exist_ok=True)
    files=['router.py','production_runtime.py','configure.py','performance-overrides.json','profiles.json']
    originals={file:(HERE/file).read_bytes() for file in files}
    for file,content in originals.items():
        dest=BACKUP/file
        if not dest.exists():dest.write_bytes(content)
    router=originals['router.py'].decode()
    router=replace_once(router,"            glm6 = Path(path).resolve()", "            qwen_rc1 = Path(path).resolve() == (ROOT/'mlx-community/Qwen3.8-Flash-Next-oQ8e-mtp').resolve() and self.profiles[path].get('qwen_runtime_version') == '0.7.1rc1'\n            if qwen_rc1: cache_path = HERE/'omlx-state-qwen-flash-rc1/cache'\n            glm6 = Path(path).resolve()")
    router=replace_once(router,"            # Pass these on every launch:","            if qwen_rc1:\n                command[0] = str(HERE/'venv-0.7.1rc1/bin/python')\n                command[command.index('--base-path')+1] = str(HERE/'omlx-state-qwen-flash-rc1')\n            # Pass these on every launch:")
    router=replace_once(router,"                command[1:2] = [str(HERE / entry), str(prefill_step)]", "                if qwen_rc1: entry = 'qwen_flash_rc1.py'\n                command[1:2] = [str(HERE / entry), str(prefill_step)]")
    router=replace_once(router,"or str(HERE/'qwen_flash_production.py') in cmd)","or str(HERE/'qwen_flash_production.py') in cmd or str(HERE/'qwen_flash_rc1.py') in cmd)")
    router=replace_once(router,"if owned and os.getpgid(pid) == pid:","if owned and isinstance(record, dict) and record.get('started') == started and started and os.getpgid(pid) == pid:")
    runtime=originals['production_runtime.py'].decode()
    runtime=replace_once(runtime,"    runtime = Path(__file__).resolve().parent / 'venv-0.7.1.dev1'", "    selected_version = '0.7.1rc1' if entries[0].resolve() == target.resolve() else '0.7.1.dev1'\n    runtime = Path(__file__).resolve().parent / ('venv-'+selected_version)")
    runtime=runtime.replace("'Qualified oMLX dev1 runtime is missing'", "'Selected production oMLX runtime is missing'")
    runtime=runtime.replace("' production runtime: oMLX 0.7.1.dev1'", "' production runtime: oMLX '+selected_version")
    runtime=runtime.replace('Use the qualified dev1 runtime for Qwen Flash Q8 and opted-in GLM.', 'Use pinned rc1 for Qwen Flash Q8; retain the existing opted-in GLM fallback.')
    configure=originals['configure.py'].decode()
    block="""    # Dedicated native rc1 state for Qwen Flash; never reuse the dev1 prefix cache.
    qwen = ROOT/'mlx-community/Qwen3.8-Flash-Next-oQ8e-mtp'
    if str(qwen) in profiles and profiles[str(qwen)].get('qwen_runtime_version') == '0.7.1rc1':
        own_state = HERE/'omlx-state-qwen-flash-rc1'
        own_state.mkdir(exist_ok=True)
        own = copy.deepcopy(settings)
        own['cache'].update(hot_cache_max_size='2GB',ssd_cache_dir=str(own_state/'cache'))
        own['memory'].update(memory_guard_tier='custom',memory_guard_custom_ceiling_gb=112.0)
        own['server']['burst_decode_mode'] = 'aggressive'
        (own_state/'settings.json').write_text(json.dumps(own,indent=2)+'\\n')
        (own_state/'model_settings.json').write_text(json.dumps({'version':1,'models':{qwen.name:profiles[str(qwen)]}},indent=2)+'\\n')
"""
    if 'Dedicated native rc1 state for Qwen Flash' not in configure:
        configure=replace_once(configure,'    return profiles\n',block+'    return profiles\n')
    overrides=json.loads(originals['performance-overrides.json'])
    p=overrides[NAME]
    p.update(qwen_runtime_version='0.7.1rc1',qwen_prediction_disabled=False,
             display_name='Qwen Flash · Q8 · rc1 · Native scheduler',
             description='Production oMLX0.7.1rc1 / MLX0.32.4; native scheduler as validated in single cold-cache16K test. 60% expert residency, 8192 prefill, native KV, adaptive MTP<=3, 112GiB guard; isolated rc1 prefix cache.')
    contents={'router.py':router,'production_runtime.py':runtime,'configure.py':configure,
              'performance-overrides.json':json.dumps(overrides,indent=2)+'\n',
              'qwen_flash_rc1.py':(Path(__file__).parent/'qwen_flash_rc1.py').read_text()}
    for file,text in contents.items():
        if file.endswith('.py'):ast.parse(text,filename=file)
    versions=subprocess.check_output([str(HERE/'venv-0.7.1rc1/bin/python'),'-c',
        "from importlib.metadata import version; print(version('omlx'),version('mlx'))"],text=True).strip()
    if versions!='0.7.1rc1 0.32.4':raise RuntimeError('Unexpected installed versions: '+versions)
    try:
        for file,text in contents.items():
            temp=HERE/(file+'.rc1-tmp');temp.write_text(text);temp.replace(HERE/file)
        subprocess.run([sys.executable,str(HERE/'configure.py')],check=True,cwd=REPO)
        subprocess.run(['node',str(HERE.parent/'configure.mjs')],check=True,cwd=REPO)
    except BaseException:
        for file,content in originals.items():(HERE/file).write_bytes(content)
        raise
    receipt={'at':datetime.now(timezone.utc).isoformat(),'version':versions,'model':NAME,
             'state':str(HERE/'omlx-state-qwen-flash-rc1'),'backup':str(BACKUP),
             'files':{file:hashlib.sha256((HERE/file).read_bytes()).hexdigest() for file in contents}}
    (BACKUP/'deployment.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt,indent=2))


if __name__=='__main__':main()

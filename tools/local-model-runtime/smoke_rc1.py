"""Production route startup/load validation, without a generation benchmark."""
import fcntl
import json
import os
from pathlib import Path
import socket
import sys

REPO=Path(__file__).resolve().parents[2]
HERE=Path.home()/'.local/share/deepseek-harness/local-mlx'
OUT=REPO/'audit/reviews/dsh-rc1-production-20261017'
lock=(HERE/'session.lock').open('a')
fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
for port in (8090,8092):
    with socket.socket() as check:
        if check.connect_ex(('127.0.0.1',port))==0:raise RuntimeError('Existing local model session; refusing interruption')
sys.path.insert(0,str(HERE))
import router
log=HERE/'backend.log'
start=log.stat().st_size if log.exists() else 0
manager=router.Manager()
report={'generation_requests':0}
try:
    manager.select('mlx-community/Qwen3.8-Flash-Next-oQ8e-mtp')
    args=manager.process.args
    assert args[0]==str(HERE/'venv-0.7.1rc1/bin/python'),args
    assert args[1]==str(HERE/'qwen_flash_rc1.py'),args
    assert args[args.index('--base-path')+1]==str(HERE/'omlx-state-qwen-flash-rc1'),args
    assert args[args.index('--paged-ssd-cache-dir')+1]==str(HERE/'omlx-state-qwen-flash-rc1/cache'),args
    report.update(status='PASS',command=args,models=manager.backend('GET','/v1/models/status'))
finally:
    manager.stop()
    report['owned_backend_stopped']=manager.process is None
    tail=log.read_bytes()[start:].decode(errors='replace')
    (OUT/'production-server.log').write_text(tail)
    report['native_rc1_marker']='Qwen Flash production: native oMLX0.7.1rc1 / MLX0.32.4' in tail
    (OUT/'production-smoke.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:report[k] for k in ['status','generation_requests','owned_backend_stopped','native_rc1_marker']},indent=2))

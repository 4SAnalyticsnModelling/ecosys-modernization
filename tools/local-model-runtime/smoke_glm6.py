"""Load the deployed GLM6 through its real router; issue no generation requests."""
import fcntl
import json
from pathlib import Path
import socket
import sys

REPO=Path(__file__).resolve().parents[2]
HERE=Path('/Users/4sanalyticsnmodelling/.local/share/deepseek-harness/local-mlx')
OUT=REPO/'audit/reviews/glm6-speed-20261017'
NAME='GLM-5.3-Flash-MLX-6bit'


def main():
    lock=(HERE/'session.lock').open('r');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    for port in (8090,8092):
        with socket.socket() as sock:
            if sock.connect_ex(('127.0.0.1',port))==0:raise RuntimeError('Existing inference session')
    sys.path.insert(0,str(HERE))
    import router
    expected=json.loads((OUT/'deployment.json').read_text())
    profile=json.loads((HERE/'performance-overrides.json').read_text())[NAME]
    assert profile['enable_thinking'] is True
    assert profile['chat_template_kwargs']['reasoning_effort']=='max'
    log=HERE/'backend.log';offset=log.stat().st_size if log.exists() else 0
    manager=router.Manager();report=dict(generation_requests=0)
    try:
        manager.select(NAME)
        args=manager.process.args
        assert args[0]==str(HERE/'venv-0.7.1rc1/bin/python')
        assert args[1]==str(HERE/'glm6_production.py')
        assert args[2]==str(expected['chunk'])
        assert profile['glm6_decode_lookahead_width']==expected['width']
        report.update(command=args,models=manager.backend('GET','/v1/models/status'))
        slots=json.loads((HERE/'omlx-state-glm6-r35/residency.json').read_text())
        assert len(slots)==42 and all(s==dict(capacity=101,total=288) for s in slots)
        fresh_log=log.read_bytes()[offset:].decode(errors='replace')
        assert 'GLM6 production residency verified: 42 x 101/288' in fresh_log
        if expected['width']:
            assert f"GLM6 bounded decode lookahead: {expected['width']}" in fresh_log
        report['status']='PASS'
    except BaseException as error:
        report['status']='FAIL';report['error']=repr(error);raise
    finally:
        manager.stop()
        report['owned_backend_stopped']=manager.process is None
        (OUT/'production-smoke-server.log').write_bytes(log.read_bytes()[offset:])
        (OUT/'production-smoke.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__':main()

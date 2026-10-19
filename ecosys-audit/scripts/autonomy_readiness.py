"""Verify live deployment evidence before unattended mission supervision (never activate services)."""
import argparse
import json
import platform
import shutil
from pathlib import Path
from workflow import ROOT, ProtocolError, artifact, digest, encoded, file_digest, inside, load, verify_artifacts

CASES={'worker-crash','early-exit','context-resume','network-recovery','supervisor-crash',
       'reboot-service','storage-pressure','backup-restore','no-progress-replan','blocked-resume','publication-recovery'}


def identity(root,config):
    executable=shutil.which(config['command'][0])
    if not executable:raise ProtocolError('worker harness unavailable')
    files=[str(Path(__file__).resolve()),str(Path(__file__).with_name('worker_supervisor.py').resolve()),
           str(Path(__file__).with_name('progress_watch.py').resolve())]+config.get('runtime_dependencies',[])
    return digest(encoded({'root':str(root.resolve()),'platform':platform.platform(),'machine':platform.machine(),
        'config':config,'harness_sha256':file_digest(Path(executable)),
        'runtime_files':{p:file_digest(Path(p) if Path(p).is_absolute() else inside(root,p)) for p in files}}))


def check(root,config,certificate='.agent/autonomy-readiness.json'):
    try:
        current=identity(root,config);report=load(inside(root,certificate))
        if report.get('mode')!='LIVE' or report.get('identity')!=current:raise ProtocolError('synthetic/stale runtime qualification')
        if report.get('status')!='PASS' or set(report.get('cases',{}))!=CASES:raise ProtocolError('missing live recovery cases')
        for name,ref in report['cases'].items():
            if artifact(root,ref['path'])!=ref:raise ProtocolError('stale live case: '+name)
            case=load(inside(root,ref['path']))
            if case.get('case')!=name or case.get('mode')!='LIVE' or case.get('identity')!=current or case.get('status')!='PASS':
                raise ProtocolError('unverified live case: '+name)
            if not case.get('assertions') or not case.get('evidence'):raise ProtocolError('missing recovery assertions/evidence: '+name)
            verify_artifacts(root,case['evidence'])
        reserve=config.get('storage_reserve_bytes')
        if type(reserve) is not int or reserve<=0:raise ProtocolError('set storage reserve from measured retention/growth plan')
        if shutil.disk_usage(root).free<reserve:raise ProtocolError('storage reserve not available')
        return []
    except (OSError,ValueError,KeyError,TypeError,ProtocolError) as exc:return [str(exc)]


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--config',default='.agent/worker.json');p.add_argument('--identity',action='store_true')
    a=p.parse_args();config=load(inside(ROOT,a.config))
    result={'identity':identity(ROOT,config)} if a.identity else {'problems':check(ROOT,config)}
    print(json.dumps(result,indent=2));raise SystemExit(bool(result.get('problems')))

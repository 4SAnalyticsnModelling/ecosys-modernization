"""Read-only, bounded worker recovery packet from live ledgers and process receipts."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
from workflow import ROOT
from project_runtime import git, owned_alive

def read(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as e:
        return {'read_error': str(e)}

def collect(root: Path = ROOT) -> dict:
    cycle = read(root / '.agent/cycle.json'); frontier = read(root / '.agent/frontier.json')
    jobs = []
    # Inspect every receipt for RUNNING jobs; never infer death from heartbeat age.
    for path in (root / 'audit/runs').rglob('receipt.json'):
        r = read(path)
        if r.get('status') == 'RUNNING':
            jobs.append({'receipt': str(path.relative_to(root)), 'pid': r.get('pid'),
                         'identity_verified_alive': owned_alive(r),
                         'identity_available': bool(r.get('process_start'))})
    if cycle.get('status')=='DECIDED' and cycle.get('closure'):
        try:
            committed=json.loads(git(root,'show','HEAD:.agent/cycle.json'))
            if committed==cycle and git(root,'rev-parse','HEAD').strip()==git(root,'rev-parse','origin/main').strip():
                cycle=dict(cycle,status='PUSHED',sync_status='derived from matching Git refs; refresh origin before next cycle')
        except Exception:pass
    cycle = {k:cycle[k] for k in ['cycle','status','target','next_target','record','base_commit','owned_paths','next_action'] if k in cycle}
    frontier = {k:frontier[k] for k in ['verified_frontier','simulation_frontier','current_failure_hour','last_checkpoint_key'] if k in frontier}
    status = git(root, 'status', '--short').decode().splitlines()
    return {'head': git(root, 'rev-parse', 'HEAD').decode().strip(),
            'git_status': status[:30], 'git_status_total':len(status), 'git_status_truncated':len(status)>30,
            'cycle': cycle, 'frontier': frontier, 'running_receipts': jobs[:20], 'running_receipts_total':len(jobs),
            'instruction': 'Resume cycle target. Reconcile dirty edits and live/unknown jobs before any retry. '
                           'Frontier is strict evidence, cycle target can be a later diagnostic hour. '
                           'Read .agent/backlog.md and only the current issue/receipt next.'}

def main():
    p = argparse.ArgumentParser(description=__doc__); p.add_argument('--root', type=Path, default=ROOT)
    a = p.parse_args(); print(json.dumps(collect(a.root.resolve()), indent=2))
if __name__ == '__main__':
    main()

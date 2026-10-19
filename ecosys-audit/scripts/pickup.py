"""Read-only, bounded worker recovery packet from live ledgers and process receipts."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
from workflow import ROOT
from project_runtime import git, job_state

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
            state = job_state(r)
            jobs.append({'receipt': str(path.relative_to(root)), 'pid': r.get('pid'),
                         'state': state, 'identity_verified_alive': state == 'alive',
                         'identity_available': bool(r.get('process_start')),
                         'reconciliation': {'alive': 'Observe the existing process; do not duplicate it.',
                            'dead': 'Inspect logs, final outputs and checkpoints; process death does not establish outcome.',
                            'unknown': 'Establish process/start identity or independent termination evidence before retry.'}[state],
                         'artifact_candidates': [str(p.relative_to(root)) for p in
                            sorted(path.parent.iterdir()) if p.is_file() and p.name in
                            ('stdout.log','stderr.log','summary.json','receipt.json')],
                         'automatic_retry_allowed': False})
    if cycle.get('status')=='DECIDED' and cycle.get('closure'):
        try:
            committed=json.loads(git(root,'show','HEAD:.agent/cycle.json'))
            if committed==cycle and git(root,'rev-parse','HEAD').strip()==git(root,'rev-parse','origin/main').strip():
                cycle=dict(cycle,status='PUSHED',sync_status='derived from matching Git refs; refresh origin before next cycle')
        except Exception:pass
    cycle = {k:cycle[k] for k in ['cycle','status','target','next_target','record','base_commit','owned_paths','next_action'] if k in cycle}
    frontier = {k:frontier[k] for k in ['verified_frontier','simulation_frontier','current_failure_hour','last_checkpoint_key',
                'verified_frontier_note','simulation_frontier_note','candidate_commit','evidence_binding'] if k in frontier}
    status = git(root, 'status', '--short').decode().splitlines()
    return {'head': git(root, 'rev-parse', 'HEAD').decode().strip(),
            'git_status': status[:30], 'git_status_total':len(status), 'git_status_truncated':len(status)>30,
            'cycle': cycle, 'frontier': frontier, 'running_receipts': jobs[:20], 'running_receipts_total':len(jobs),
            'running_receipts_truncated': len(jobs)>20,
            'progress_provenance': {'qualified': '.agent/frontier.json:verified_frontier',
                'historical_run': '.agent/frontier.json:simulation_frontier/current_failure_hour; use recorded binding and notes',
                'diagnostic_target': '.agent/cycle.json:target; does not promote qualified progress'},
            'instruction': 'Resume cycle target. Reconcile dirty edits and live/unknown jobs before any retry. '
                           'Frontier is strict evidence, cycle target can be a later diagnostic hour. '
                           'Read .agent/backlog.md and only the current issue/receipt next.'}

def main():
    p = argparse.ArgumentParser(description=__doc__); p.add_argument('--root', type=Path, default=ROOT)
    a = p.parse_args(); print(json.dumps(collect(a.root.resolve()), indent=2))
if __name__ == '__main__':
    main()

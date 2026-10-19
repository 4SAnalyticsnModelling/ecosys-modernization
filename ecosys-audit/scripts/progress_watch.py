"""Persistent semantic restart guard. Wall time, log growth and restart count are not progress."""
from workflow import encoded, digest, load, artifact
from project_runtime import content_digest, SOURCE_SCOPE


def signature(root):
    def read(path):
        try:return load(root/path)
        except (OSError,ValueError):return {}
    frontier=read('.agent/frontier.json')
    cycle=read('.agent/cycle.json')
    gates=[]
    for name,g in sorted(cycle.get('gates',{}).items()):
        # Hash contents, not newly allocated filenames or dates. Stale claims earn no progress.
        refs=g.get('evidence',[])
        try:valid=bool(refs) and all(artifact(root,r['path'])==r for r in refs)
        except (OSError,KeyError,RuntimeError):valid=False
        if valid and g.get('result') in ('PASS','NA'):
            # Rerunning an identical check writes different timings/log hashes. Count a new
            # accepted candidate/outcome, not its freshly written receipt bytes.
            gates.append([name,g.get('result'),g.get('candidate_digest')])
    return digest(encoded({'source':content_digest(root,SOURCE_SCOPE),
        'frontier':[frontier.get('verified_frontier'),frontier.get('evidence_binding')], 'gates':gates}))


def observe(previous, before, after):
    history=previous.get('progress_history',[])
    if before not in history:history.append(before)
    advanced=after!=before and after not in history
    if advanced:history.append(after)
    # Retain history across supervisor crashes, including A -> B -> A oscillation.
    return {'progress_history':history, 'no_progress_exits':0 if advanced else previous.get('no_progress_exits',0)+1,
            'progress_signature':after, 'meaningful_state_changed':advanced}


def action(previous, current):
    stalled=previous.get('no_progress_exits',0)
    if current not in previous.get('progress_history',[]):return 'RESUME'
    if stalled>=4:return 'WAITING_FOR_CHANGE'
    if stalled>=3:return 'REPLAN'
    return 'RESUME'

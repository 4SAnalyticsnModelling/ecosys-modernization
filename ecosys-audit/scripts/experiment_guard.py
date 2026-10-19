"""Reject unchanged failed/unfinished Ottawa launches; filenames are not new experiments."""
from workflow import ProtocolError, artifact, atomic, digest, encoded, inside, load, lock, verify_artifacts


def claim(root,definition,run_id,recovery=None):
    key=digest(encoded(definition));directory=root/'audit/experiments';directory.mkdir(parents=True,exist_ok=True)
    path=directory/(key+'.json')
    with lock(root/'.agent/locks/experiment-guard.lock'):
        data=load(path) if path.exists() else {'definition':definition,'attempts':[],'recoveries':[]}
        attempts=data['attempts'];previous=attempts[-1] if attempts else None
        if previous and previous['status']!='SUCCEEDED':
            if previous['status']=='SCIENTIFIC_FAILURE':
                raise ProtocolError('unchanged scientific failure: '+str(path.relative_to(root))+'; change the causal experiment/source/inputs first')
            if not recovery:raise ProtocolError('reconcile unfinished/infrastructure experiment before retry: '+str(path.relative_to(root)))
            decision=load(inside(root,recovery));ref=artifact(root,recovery)
            if (decision.get('classification')!='INFRASTRUCTURE' or decision.get('experiment_key')!=key
                    or decision.get('prior_run_id')!=previous['run_id'] or not decision.get('diagnosis')
                    or not decision.get('resource_identity') or not decision.get('evidence')):
                raise ProtocolError('retry requires bound infrastructure diagnosis, termination proof and changed prerequisite')
            verify_artifacts(root,decision['evidence'])
            if decision.get('prior_process_terminated') is not True:raise ProtocolError('prior process termination not established')
            if previous.get('error') and (decision.get('scientific_failure_ruled_out') is not True or not decision.get('classification_evidence')):
                raise ProtocolError('heuristic scientific error needs explicit evidence ruling it out before infrastructure retry')
            if previous.get('error'):verify_artifacts(root,decision['classification_evidence'])
            resource=decision['resource_identity']
            if resource in data['recoveries']:raise ProtocolError('unchanged infrastructure recovery already consumed')
            data['recoveries'].append(resource)
            previous['recovery']=ref
        attempts.append({'run_id':run_id,'status':'RUNNING'})
        atomic(path,encoded(data))
    return key


def finish(root,key,summary):
    path=root/'audit/experiments'/(key+'.json');value=load(inside(root,summary))
    with lock(root/'.agent/locks/experiment-guard.lock'):
        data=load(path);attempt=data['attempts'][-1]
        if value['run_id']!=attempt['run_id']:raise ProtocolError('experiment completion owner mismatch')
        attempt['status']=('SCIENTIFIC_FAILURE' if value.get('failure_classification')=='SCIENTIFIC' else
                           'SUCCEEDED' if value.get('exit_code')==0 else 'RECONCILE')
        attempt['error']=value.get('error')
        attempt['summary']=artifact(root,summary);atomic(path,encoded(data))

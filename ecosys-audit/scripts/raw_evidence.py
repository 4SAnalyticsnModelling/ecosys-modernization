"""Recompute conservation and output verdicts from immutable streams and frozen policies."""
from collections import defaultdict
import importlib.util
import itertools
import json
import math
from workflow import ProtocolError, artifact, inside, load
from project_runtime import git
from performance_check import read_ref

METRICS=('instantaneous','event_timing','seasonal','annual','cumulative')


def require(ok,message):
    if not ok:raise ProtocolError(message)


def finite(value):
    require(type(value) in (int,float) and math.isfinite(value),'nonfinite/nonnumeric raw value')
    return value


def tolerance(rule):
    for name in ('abs','rel'):
        require(finite(rule[name])>=0,'negative tolerance')
    require(bool(rule.get('rationale')),'missing scientific tolerance rationale')


def policy(root,spec):
    ref=spec['policy'];data=read_ref(root,ref)
    require(data.get('status')=='ESTABLISHED' and data.get('decision') and data.get('evidence'),'unestablished raw acceptance policy')
    from workflow import verify_artifacts
    verify_artifacts(root,data['evidence'])
    commit=spec['policy_commit']
    require(git(root,'show',commit+':'+ref['path'])==inside(root,ref['path']).read_bytes(),'policy differs from predeclared committed version')
    git(root,'merge-base','--is-ancestor',commit,'HEAD')
    defined=int(git(root,'show','-s','--format=%ct',commit))
    receipts=spec['evaluation_receipts'];require(bool(receipts),'missing evaluation receipts')
    for r in receipts:
        receipt=read_ref(root,r)
        require(receipt.get('status')=='EXITED' and receipt.get('exit_code')==0,'failed evaluation run')
        require(finite(receipt['started_unix'])>=defined,'rules were defined after evaluation began')
    return data


def balance(root,item,expected,spec,hours):
    rules=policy(root,spec);rule=rules['variables'][expected['rule']];tolerance(rule)
    ref=item['ledger'];require(artifact(root,ref['path'])==ref,'stale ledger stream')
    previous=None;n=0
    with inside(root,ref['path']).open() as f:
        for line in f:
            row=json.loads(line);n+=1
            require(type(row['hour']) is int and row['hour']==n,'missing/duplicate/out-of-order ledger hour')
            require(all(row[k]==expected[k] for k in ('quantity','level','location','units')),'ledger identity/units mismatch')
            old,new=finite(row['old']),finite(row['new'])
            require(previous is None or old==previous,'discontinuous storage ledger')
            sources=[finite(v) for v in row['sources']];sinks=[finite(v) for v in row['sinks']]
            residual=math.fsum([new,-old]+[-v for v in sources]+sinks)
            scale=max(abs(old),abs(new),math.fsum(abs(v) for v in sources+sinks))
            require(abs(finite(residual))<=finite(rule['abs']+rule['rel']*scale),'raw conservation breach at hour '+str(n))
            previous=new
    require(n==hours,'raw ledger does not cover full campaign')


def metric_rules(rule):
    tolerance(rule)
    metrics=rule['metrics'];require(set(metrics)==set(METRICS),'define every acceptance metric or justified NA')
    for name,m in metrics.items():
        require(bool(m.get('rationale')),'metric needs rationale')
        if m.get('status')=='NA':
            require(name!='instantaneous','instantaneous comparison cannot be omitted');continue
        require(m.get('status')=='REQUIRED','invalid metric status');tolerance(m)
        if name!='instantaneous':
            allowed=('peak_time','first_above') if name=='event_timing' else ('sum','mean','min','max')
            require(m.get('reducer') in allowed,'unsupported metric reducer')
            if m['reducer']=='first_above':finite(m['threshold'])


def within(a,b,rule):
    require(abs(b-a)<=finite(rule['abs']+rule['rel']*abs(a)),'raw output exceeds '+rule.get('rationale','rule'))


def accumulate(state, value, when, rule):
    # Neumaier summation bounds memory while retaining low-order bits in long totals.
    total=state.get('sum',0.0);updated=total+value
    state['correction']=state.get('correction',0.0)+((total-updated)+value if abs(total)>=abs(value) else (value-updated)+total)
    state['sum']=updated;state['count']=state.get('count',0)+1
    state['min']=min(state.get('min',value),value)
    if 'max' not in state or value>state['max']:state.update(max=value,peak_time=when)
    if rule['reducer']=='first_above' and value>=rule['threshold']:state.setdefault('first_above',when)


def reduced(state, reducer):
    if reducer in ('sum','mean'):
        total=state['sum']+state['correction']
        return total/state['count'] if reducer=='mean' else total
    return state.get(reducer)


def outputs(root,required,spec):
    rules=policy(root,spec);pairs=spec['pairs'];require(bool(pairs),'empty raw output pairs')
    adapter=spec['adapter'];require(artifact(root,adapter['path'])==adapter,'stale raw adapter')
    require(inside(root,adapter['path']).is_relative_to(root/'ecosys-audit/adapters'),'adapter must be in audited adapter directory')
    module_spec=importlib.util.spec_from_file_location('qualification_adapter',inside(root,adapter['path']))
    module=importlib.util.module_from_spec(module_spec);module_spec.loader.exec_module(module)
    for role in ('legacy','zig'):
        directory=inside(root,spec[role+'_directory'])
        require(directory.is_dir(),'missing raw output directory')
        actual={str(p.relative_to(root)) for p in directory.rglob('*') if p.is_file()}
        supplied=[p[role]['path'] for p in pairs]
        require(len(set(supplied))==len(supplied) and actual==set(supplied),'raw file inventory mismatch: '+role)
    inventory={};counts={}
    fields={(v['file'],v['column']):(i,v) for i,v in required.items()}
    require(len(fields)==len(required),'duplicate inventory file/column')
    for pair in pairs:
        for role in ('legacy','zig'):require(artifact(root,pair[role]['path'])==pair[role],'stale raw output')
        streams=[module.rows(inside(root,pair[role]['path']),role) for role in ('legacy','zig')]
        previous=None;last_time=None;columns=None;n=0;aggregates=defaultdict(lambda:[{},{}])
        for a,b in itertools.zip_longest(*streams):
            require(a is not None and b is not None,'missing/extra output rows')
            key=a['key'];require(isinstance(key,list) and bool(key),'complete output key required')
            require(key==b['key'] and (previous is None or key>previous),'missing/duplicate/out-of-order output keys')
            require(a['time']==b['time'] and (last_time is None or a['time']>=last_time),'output time mismatch')
            finite(a['time']);previous=key;last_time=a['time'];n+=1
            require(a['periods']==b['periods'],'different output time support')
            actual=set(a['values']);require(bool(actual) and actual==set(b['values']),'missing/extra raw output columns')
            require(columns is None or columns==actual,'raw output columns changed within file');columns=actual
            for col in sorted(columns):
                require((pair['file'],col) in fields,'raw column omitted in reviewed inventory')
                ident,expected=fields[(pair['file'],col)];rule=rules['variables'][expected['rule']]
                if n==1:metric_rules(rule)
                values=[finite(a['values'][col]),finite(b['values'][col])]
                within(*values,rule);within(*values,rule['metrics']['instantaneous'])
                for metric,m in rule['metrics'].items():
                    if metric=='instantaneous' or m['status']=='NA':continue
                    period=a['periods']['annual' if metric=='event_timing' else metric]
                    require(isinstance(period,str) and bool(period),'missing aggregation period')
                    target=aggregates[(ident,metric,period)]
                    for i,v in enumerate(values):accumulate(target[i],v,a['time'],m)
        require(n>0,'empty raw output file')
        for col in columns:
            ident,expected=fields[(pair['file'],col)]
            require(ident not in inventory,'duplicate output file/column')
            require(expected['expected_rows']==n and expected['terminal_key']==previous,'invented output extent/terminal key')
            inventory[ident]=expected;counts[ident]=n
        for (ident,metric,period),samples in aggregates.items():
            m=rules['variables'][required[ident]['rule']]['metrics'][metric];reducer=m['reducer']
            a,b=[reduced(state,reducer) for state in samples]
            if a is None or b is None:require(a is b,'event missing from one trajectory')
            else:within(finite(a),finite(b),m)
    require(set(inventory)==set(required),'reviewed inventory has no raw counterpart')
    return counts

"""Check acceptance-definition prerequisites; empty registers remain blockers."""
from __future__ import annotations
import argparse
import csv
import json
import math
from workflow import ROOT, ProtocolError, inside, load, verify_artifacts

OUTPUT = 'audit/output-provenance.csv'
BINDINGS = 'audit/traceability/bindings.csv'
RULES = 'validation/rules/divcheck-rules.json'


def register(root, path, fields, keys):
    with inside(root,path).open(newline='') as f:
        reader=csv.DictReader(f);rows=list(reader)
        if not set(fields)<=set(reader.fieldnames or []): raise ProtocolError(path+': missing required columns')
    if not rows: raise ProtocolError(path+': empty inventory')
    ids=[]
    for row in rows:
        if any(not (row.get(k) or '').strip() for k in fields): raise ProtocolError(path+': incomplete row')
        if row['status']!='VERIFIED': raise ProtocolError(path+': unverified row')
        refs=json.loads(row['evidence'])
        if not refs: raise ProtocolError(path+': missing evidence')
        verify_artifacts(root,refs)
        ids.append(tuple(row[k] for k in keys))
    if len(ids)!=len(set(ids)): raise ProtocolError(path+': duplicate keys')
    return rows


def check(root, output_inventory=None):
    errors=[];outputs=[]
    for path,fields,keys in [
        (OUTPUT,['output_file','column','fortran_origin','zig_origin','units','time_basis','kind',
                 'aggregation','conversion','comparison_rule','status','evidence'],['output_file','column']),
        (BINDINGS,['id','legacy_origin','zig_origin','shape','lower_bounds','units','time_level',
                   'initialization','reset','checkpoint','status','evidence'],['id'])]:
        try:
            rows=register(root,path,fields,keys)
            if path==OUTPUT: outputs=rows
        except (OSError,ValueError,TypeError,ProtocolError) as exc: errors.append(str(exc))
    try:
        rules=load(inside(root,RULES))
        if rules.get('status')!='ESTABLISHED' or not rules.get('decision') or not rules.get('evidence'):
            raise ProtocolError('comparison rules need an evidence-based decision before qualification')
        verify_artifacts(root,rules['evidence'])
        for row in outputs:
            rule=rules.get('variables',{}).get(row['comparison_rule'])
            if not rule or not rule.get('rationale'): raise ProtocolError('missing justified rule: '+row['comparison_rule'])
            from raw_evidence import metric_rules
            metric_rules(rule)
            for key in ('abs','rel'):
                v=rule.get(key)
                if type(v) not in (int,float) or not math.isfinite(v) or v<0: raise ProtocolError('invalid comparison tolerance')
        if not rules.get('variables'): raise ProtocolError('empty comparison rules')
    except (OSError,ValueError,KeyError,TypeError,ProtocolError) as exc: errors.append(str(exc))
    if output_inventory is not None:
        expected={(x['file'],x['column']) for x in output_inventory.values()}
        actual={(x['output_file'],x['column']) for x in outputs}
        if expected!=actual: errors.append('output dictionary does not match complete raw-output inventory')
        dictionary={(x['output_file'],x['column']):x for x in outputs}
        for item in output_inventory.values():
            row=dictionary.get((item['file'],item['column']),{})
            if any(row.get(a)!=item.get(b) for a,b in [('units','units'),('time_basis','time_basis'),('comparison_rule','rule')]):
                errors.append('output inventory units/time/rule differ from verified dictionary')
    return errors


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output-inventory',help='Reviewed F3 inventory JSON; required to establish complete output coverage')
    a=p.parse_args();items=None
    if a.output_inventory:
        from qualification_reports import inventory
        from workflow import artifact
        items=inventory(ROOT,artifact(ROOT,a.output_inventory),'F3')
    errors=check(ROOT,items)
    if items is None: errors.append('complete output inventory not supplied')
    print(json.dumps({'ready':not errors,'problems':errors},indent=2));return bool(errors)


if __name__=='__main__': raise SystemExit(main())

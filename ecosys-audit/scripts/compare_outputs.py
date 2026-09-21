#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Strict comparison of already-normalized, identically ordered CSV outputs.

This is NOT a parser for raw ecosys files or a proof of full-run completeness.
Python 3.10+, standard library only. Exit 0=PASS, 1=FAIL, 2=invalid/error.
"""
from __future__ import annotations
import argparse
import csv
from decimal import Decimal, DecimalException, localcontext
import hashlib
from itertools import zip_longest
import json
from pathlib import Path
import sys
from typing import Any

SEMANTICS={'instantaneous','interval_total','interval_mean','cumulative','categorical'}

class ComparisonError(ValueError):
    pass

def digest(path: Path)->str:
    value=hashlib.sha256()
    with path.open('rb') as handle:
        while block:=handle.read(1024*1024):
            value.update(block)
    return value.hexdigest()

def unique_object(pairs: list[tuple[str,Any]])->dict:
    result={}
    for key,value in pairs:
        if key in result:
            raise ComparisonError(f'Duplicate JSON key: {key!r}')
        result[key]=value
    return result

def load_json(path: Path)->dict:
    def invalid_constant(value: str)->None:
        raise ComparisonError(f'Nonfinite JSON constant: {value}')
    result=json.loads(path.read_text(encoding='utf-8'),object_pairs_hook=unique_object,
                      parse_constant=invalid_constant)
    if not isinstance(result,dict):
        raise ComparisonError('Schema must be a JSON object.')
    return result

def number(value: object,label: str)->Decimal:
    if isinstance(value,bool) or not isinstance(value,(str,int,float,Decimal)):
        raise ComparisonError(f'{label}: expected a finite decimal number.')
    try:
        result=Decimal(str(value).strip().replace('D','E').replace('d','e'))
    except (DecimalException,ValueError) as exc:
        raise ComparisonError(f'{label}: invalid numeric value {value!r}.') from exc
    if not result.is_finite():
        raise ComparisonError(f'{label}: nonfinite value is forbidden ({value!r}).')
    return result

def validate_schema(schema: dict)->tuple[list[str],dict]:
    if schema.get('schema_version')!=1 or schema.get('status')!='APPROVED':
        raise ComparisonError('Schema must have schema_version=1 and status=APPROVED; templates cannot pass.')
    if not isinstance(schema.get('approved_by'),str) or not schema['approved_by'].strip():
        raise ComparisonError('A recorded independent tolerance reviewer is required; this is not identity authentication.')
    keys=schema.get('keys')
    columns=schema.get('columns')
    if not isinstance(keys,list) or not keys or any(not isinstance(x,str) or not x.strip() for x in keys):
        raise ComparisonError('keys must be a nonempty list of column names.')
    if len(set(keys))!=len(keys):
        raise ComparisonError('Duplicate key column names.')
    if not isinstance(columns,dict) or not columns:
        raise ComparisonError('A complete nonempty column schema is required.')
    if set(keys)&set(columns):
        raise ComparisonError('Key columns cannot also be measured columns.')
    parsed={}
    for name,spec in columns.items():
        if not isinstance(name,str) or not name.strip() or not isinstance(spec,dict):
            raise ComparisonError('Malformed column schema.')
        kind=spec.get('kind')
        if kind not in {'number','text'}:
            raise ComparisonError(f'{name}: kind must be number or text.')
        if spec.get('semantics') not in SEMANTICS:
            raise ComparisonError(f'{name}: declare the actual temporal/categorical semantics.')
        if not isinstance(spec.get('rationale'),str) or not spec['rationale'].strip():
            raise ComparisonError(f'{name}: tolerance/comparison rationale is required.')
        missing=spec.get('missing_tokens',[])
        if not isinstance(missing,list) or any(not isinstance(x,str) for x in missing) or len(set(missing))!=len(missing):
            raise ComparisonError(f'{name}: missing_tokens must be unique exact strings.')
        for token in missing:
            try:
                value=Decimal(token.strip().replace('D','E').replace('d','e'))
            except DecimalException:
                continue
            if not value.is_finite():
                raise ComparisonError(f'{name}: NaN/Inf cannot be accepted as missing tokens.')
        minimum=spec.get('min_valid_pairs',1)
        if isinstance(minimum,bool) or not isinstance(minimum,int) or minimum<1:
            raise ComparisonError(f'{name}: min_valid_pairs must be an integer >=1.')
        item={**spec,'missing_tokens':set(missing),'min_valid_pairs':minimum}
        if kind=='number':
            if not isinstance(spec.get('units'),str) or not spec['units'].strip():
                raise ComparisonError(f'{name}: numeric units are required.')
            for key in ('atol','rtol','scale_floor'):
                value=number(spec.get(key),f'{name}.{key}')
                if value<0:
                    raise ComparisonError(f'{name}.{key}: must be nonnegative.')
                item[key]=value
        parsed[name]=item
    return keys,parsed

def compare(reference: Path,candidate: Path,schema: dict)->dict:
    keys,specs=validate_schema(schema)
    expected=keys+list(specs)
    reference_before=digest(reference)
    candidate_before=digest(candidate)
    stats={name:{'kind':spec['kind'],'valid_pairs':0,'both_missing':0,'failures':0,
                 'max_abs':Decimal(0),'max_abs_key':None,'sum_delta':Decimal(0),
                 'sum_abs':Decimal(0),'sum_squares':Decimal(0),'max_tolerance_ratio':Decimal(0),
                 'zero_tolerance_violations':0,'first_failure':None}
           for name,spec in specs.items()}
    row_count=0
    seen=set()
    examples=[]
    with localcontext() as context:
        context.prec=50
        with reference.open(newline='',encoding='utf-8-sig') as first, candidate.open(newline='',encoding='utf-8-sig') as second:
            ref_reader=csv.reader(first,strict=True)
            new_reader=csv.reader(second,strict=True)
            for label,reader in [('reference',ref_reader),('candidate',new_reader)]:
                header=next(reader,None)
                if header!=expected:
                    raise ComparisonError(f'{label}: header must exactly match schema order {expected!r}; got {header!r}.')
            for row_index,pair in enumerate(zip_longest(ref_reader,new_reader),start=2):
                left,right=pair
                if left is None or right is None:
                    raise ComparisonError(f'Unequal row counts at CSV row {row_index}; missing/extra records are not skipped.')
                if len(left)!=len(expected) or len(right)!=len(expected):
                    raise ComparisonError(f'Wrong field count at CSV row {row_index}.')
                key=tuple(left[:len(keys)])
                new_key=tuple(right[:len(keys)])
                if any(not part.strip() for part in key+new_key):
                    raise ComparisonError(f'Empty key at CSV row {row_index}.')
                if key!=new_key:
                    raise ComparisonError(f'Key/order mismatch at CSV row {row_index}: {key!r} vs {new_key!r}. Normalize and explicitly align keys; do not ignore rows.')
                if key in seen:
                    raise ComparisonError(f'Duplicate key at CSV row {row_index}: {key!r}.')
                seen.add(key)
                row_count+=1
                key_dict=dict(zip(keys,key))
                for offset,(name,spec) in enumerate(specs.items(),start=len(keys)):
                    old,new=left[offset],right[offset]
                    state=stats[name]
                    old_missing=old in spec['missing_tokens']
                    new_missing=new in spec['missing_tokens']
                    # Nonfinite numbers are errors even if the other side is a
                    # legitimate missing value; never let a missing branch hide them.
                    if spec['kind']=='number':
                        x=None if old_missing else number(old,f'reference {name}, key={key!r}')
                        y=None if new_missing else number(new,f'candidate {name}, key={key!r}')
                    if old_missing and new_missing:
                        state['both_missing']+=1
                        continue
                    mismatch=None
                    if old_missing!=new_missing:
                        mismatch={'reason':'missingness differs','reference':old,'candidate':new}
                    elif spec['kind']=='text':
                        state['valid_pairs']+=1
                        if old!=new:
                            mismatch={'reason':'exact text mismatch','reference':old,'candidate':new}
                    else:
                        assert x is not None and y is not None
                        delta=y-x
                        absolute=abs(delta)
                        threshold=spec['atol']+spec['rtol']*max(abs(x),spec['scale_floor'])
                        state['valid_pairs']+=1
                        state['sum_delta']+=delta
                        state['sum_abs']+=absolute
                        state['sum_squares']+=delta*delta
                        if state['max_abs_key'] is None or absolute>state['max_abs']:
                            state['max_abs']=absolute
                            state['max_abs_key']=key_dict
                        if threshold>0:
                            state['max_tolerance_ratio']=max(state['max_tolerance_ratio'],absolute/threshold)
                        elif absolute>0:
                            state['zero_tolerance_violations']+=1
                        if absolute>threshold:
                            mismatch={'reason':'numeric tolerance exceeded','reference':old,'candidate':new,
                                      'absolute_error':str(absolute),'threshold':str(threshold)}
                    if mismatch:
                        state['failures']+=1
                        item={'column':name,'key':key_dict,**mismatch}
                        if state['first_failure'] is None:
                            state['first_failure']=item
                        if len(examples)<20:
                            examples.append(item)
        if row_count==0:
            raise ComparisonError('No data rows; empty outputs cannot pass.')
        reports={}
        any_failure=False
        for name,spec in specs.items():
            state=stats[name]
            minimum_ok=state['valid_pairs']>=spec['min_valid_pairs']
            failed=state['failures']>0 or not minimum_ok
            any_failure=any_failure or failed
            report={'status':'FAIL' if failed else 'PASS','kind':spec['kind'],
                    'semantics':spec['semantics'],'valid_pairs':state['valid_pairs'],
                    'both_missing':state['both_missing'],'failed_pairs':state['failures'],
                    'minimum_valid_pairs_met':minimum_ok,'first_failure':state['first_failure']}
            if spec['kind']=='number':
                count=state['valid_pairs']
                report.update({'units':spec['units'],'max_abs_error':str(state['max_abs']) if count else None,
                               'max_abs_key':state['max_abs_key'],
                               'mean_bias':str(state['sum_delta']/count) if count else None,
                               'mae':str(state['sum_abs']/count) if count else None,
                               'rmse':str((state['sum_squares']/count).sqrt()) if count else None,
                               'max_tolerance_ratio':str(state['max_tolerance_ratio']) if count else None,
                               'zero_tolerance_violations':state['zero_tolerance_violations']})
            reports[name]=report
    if digest(reference)!=reference_before or digest(candidate)!=candidate_before:
        raise ComparisonError('An input changed during comparison; freeze completed output files before comparing.')
    return {'schema_version':1,'status':'FAIL' if any_failure else 'PASS','rows_compared':row_count,
            'reference_sha256':reference_before,'candidate_sha256':candidate_before,
            'columns':reports,'first_failure_examples':examples,
            'limitations':'Normalized CSV comparison only. Does not prove raw-parser correctness, run/file/key inventory completeness, physical validity, or scientific approval of tolerances.'}

def write_report(path: Path,report: dict)->None:
    path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('x',encoding='utf-8') as handle:
        json.dump(report,handle,indent=2,allow_nan=False)
        handle.write('\n')

def main()->int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference',required=True,type=Path)
    parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--schema',required=True,type=Path)
    parser.add_argument('--report',required=True,type=Path,help='New report path; existing files are never overwritten')
    args=parser.parse_args()
    if args.report.exists() or args.report.resolve() in {args.reference.resolve(),args.candidate.resolve(),args.schema.resolve()}:
        print('Report destination exists or overlaps an input; choose a new path.',file=sys.stderr)
        return 2
    try:
        schema_before=digest(args.schema)
        schema=load_json(args.schema)
        result=compare(args.reference,args.candidate,schema)
        if digest(args.schema)!=schema_before:
            raise ComparisonError('Tolerance schema changed during comparison; use a frozen reviewed schema.')
        result['schema_sha256']=schema_before
        code=0 if result['status']=='PASS' else 1
    except (OSError,ValueError,DecimalException,csv.Error) as exc:
        result={'schema_version':1,'status':'ERROR','message':str(exc)}
        code=2
    try:
        write_report(args.report,result)
    except OSError as exc:
        print(f'Cannot write report: {exc}',file=sys.stderr)
        return 2
    print(json.dumps({'status':result['status'],'report':str(args.report),'message':result.get('message')},indent=2))
    return code

if __name__=='__main__':
    raise SystemExit(main())

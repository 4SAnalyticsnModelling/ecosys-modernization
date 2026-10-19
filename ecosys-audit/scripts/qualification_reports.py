"""Validate F2–F6 report coverage and outcomes, in addition to artifact identity.

This checks machine-readable evidence contracts, not the truth of scientific derivations.
Raw evidence and separate verification remain mandatory. See qualification-evidence.md.
"""
from __future__ import annotations
import math
import re
from workflow import ProtocolError, artifact, inside, load, verify_artifacts
from dependencies import verify as verify_dependencies

HOURS = 262920
METHODS = ('separate-derivation', 'fresh-context-same-model')
F6_CASES = {'build-Debug', 'build-ReleaseSafe', 'build-ReleaseFast',
            'restart-active-science', 'restart-calendar-repeat', 'restart-corrupt-truncated',
            'restart-spatial-nonunit', 'releasefast-safety', 'reproducibility',
            'equivalent-work-performance', 'memory-build-report'}
F6_CASES |= {f'tests-{root}-{mode}' for root in ('module', 'executable')
             for mode in ('Debug', 'ReleaseSafe', 'ReleaseFast')}


def require(condition, message):
    if not condition: raise ProtocolError(message)


def refs(root, values):
    require(isinstance(values, list) and bool(values), 'supporting evidence is empty')
    verify_artifacts(root, values)
    require(all(inside(root, x['path']).stat().st_size for x in values), 'empty supporting artifact')


def referenced(root, ref):
    require(isinstance(ref, dict) and artifact(root, ref['path']) == ref, 'stale referenced report/inventory')
    return load(inside(root, ref['path']))


def inventory(root, ref, gid):
    inv = referenced(root, ref)
    require(inv.get('schema_version') == 1 and inv.get('criterion') == gid, 'invalid inventory schema/criterion')
    require(inv.get('scope_complete') is True and inv.get('verification_method') in METHODS,
            'inventory completeness needs separate review')
    refs(root, inv.get('evidence'))
    items = inv.get('items')
    require(isinstance(items, list) and bool(items), 'empty required inventory')
    ids = [item['id'] for item in items]
    require(all(isinstance(i, str) and i.strip() for i in ids) and len(ids) == len(set(ids)),
            'invalid/duplicate inventory IDs')
    return {item['id']: item for item in items}


def count(value):
    return type(value) is int and value >= 0


def zeroes(item, names):
    for name in names:
        require(type(item.get(name)) is int and item[name] == 0, name + ' missing or nonzero')


def text_fields(item, fields):
    for name in fields:
        require(isinstance(item.get(name), str) and bool(item[name].strip()), 'missing ' + name)


def validate(root, gid, report, source, binding):
    try:
        require(report.get('schema_version') == 1 and report.get('criterion') == gid, 'invalid report schema/criterion')
        require(report.get('source_digest') == source and report.get('binding_id') == binding, 'source/binding mismatch')
        require(report.get('status') == 'PASS' and report.get('unresolved') == [], 'failed/unresolved report')
        require(report.get('verification_method') in METHODS, 'missing separate verification')
        refs(root, report.get('evidence'))
        problems = verify_dependencies(root, report.get('dependencies'))
        require(not problems, '; '.join(problems))
        required = inventory(root, report['inventory'], gid)
        results = report.get('results')
        require(isinstance(results, list), 'results must be a list')
        ids = [item['id'] for item in results]
        require(len(ids) == len(set(ids)) and set(ids) == set(required), 'result/inventory coverage mismatch')
        if gid in ('F2','F3'):
            raw=referenced(root,report['raw_evidence'])
            require(raw.get('binding_id')==binding and raw.get('source_digest')==source,'raw evidence binding/source mismatch')
        if gid == 'F2':
            coverage = {(x.get('quantity'), x.get('level')) for x in required.values()}
            require({(q, level) for q in ('water', 'heat', 'C', 'N', 'P')
                     for level in ('local', 'global')} <= coverage, 'missing required conservation quantity/level')
        elif gid == 'F4':
            from source_inventory import check as check_scope
            check_scope(root,required)
            require({x.get('direction') for x in required.values()} >= {'legacy-to-zig', 'zig-to-legacy', 'state-binding'},
                    'incomplete bidirectional/state scope')
            require(any(x.get('dormant') is True for x in required.values()), 'dormant scope not inventoried')
        elif gid == 'F5':
            devs = set(re.findall(r'^\|\s*(DEV-\d+)\s*\|', (root/'audit/intentional-deviations.md').read_text(), re.M))
            require(bool(devs) and set(required) == devs, 'DEV register/inventory mismatch')
        elif gid == 'F6':
            require(F6_CASES <= set(required), 'missing required build/test/restart/performance cases')
        else:
            require(gid == 'F3', 'unsupported criterion')
            from readiness import check
            problems=check(root, required)
            require(not problems, '; '.join(problems))
            from raw_evidence import outputs
            outputs(root,required,raw)
        source_hashes={}
        for item in results:
            expected = required[item['id']]
            require(item.get('status') == 'PASS', item['id'] + ': not PASS')
            refs(root, item.get('evidence'))
            if gid == 'F2':
                require(item.get('first_hour') == 1 and item.get('last_hour') == HOURS
                        and type(item.get('hours_checked')) is int and item['hours_checked'] == HOURS,
                        item['id'] + ': incomplete hourly coverage')
                require(item.get('independent_assembly') is True, 'ledger not assembled independently')
                zeroes(item, ('missing_hours', 'duplicate_hours', 'nonfinite', 'breaches'))
                text_fields(expected, ('quantity', 'level', 'location', 'units', 'rule'))
                from raw_evidence import balance
                balance(root,item,expected,raw,HOURS)
            elif gid == 'F3':
                text_fields(expected, ('file', 'column', 'units', 'time_basis', 'rule'))
                require(count(expected.get('expected_rows')) and expected['expected_rows'] > 0,
                        'missing expected output extent')
                require(type(item.get('rows_compared')) is int and item['rows_compared'] == expected['expected_rows'],
                        'incomplete output rows')
                require(item.get('terminal_key') == expected.get('terminal_key') and bool(expected.get('terminal_key')),
                        'missing/wrong output terminal key')
                zeroes(item, ('missing', 'extra', 'duplicates', 'nonfinite', 'outside_rule'))
            elif gid == 'F4':
                require(item.get('disposition') in ('equivalent', 'justified-deviation', 'dormant-reviewed'), 'unresolved source disposition')
                require(item.get('semantics_reviewed') is True, 'mapping alone is insufficient')
                text_fields(expected, ('source', 'source_sha256', 'direction'))
                path=expected['source']
                if path not in source_hashes:source_hashes[path]=artifact(root,path)['sha256']
                require(source_hashes[path] == expected['source_sha256'], 'stale traceability source')
                text_fields(item, ('derivation', 'test_or_dormant_reason'))
            elif gid == 'F5':
                require(item.get('disposition') in ('retired', 'equivalent', 'merged'), 'unresolved DEV')
                text_fields(item, ('mechanism', 'measured_impact', 'decision'))
                require(type(expected.get('replacement_physics')) is bool, 'missing physics classification')
                if expected['replacement_physics'] and item['disposition'] != 'retired':
                    require(item.get('predeclared_envelope') is True and item.get('held_out_benchmarks') is True,
                            'replacement physics lacks predeclared/held-out validation')
            elif gid == 'F6':
                if item['id'].startswith('build-'):
                    receipt=referenced(root,item['build_receipt'])
                    require(receipt.get('status')=='EXITED' and receipt.get('exit_code')==0
                            and receipt.get('build_mode')==item['id'][6:]
                            and receipt.get('source_digest')==source
                            and receipt.get('source_changed_during_command') is False
                            and str(receipt.get('toolchain',{}).get('zig',{}).get('version','')).startswith('0.17.'),
                            'unverified/stale build receipt')
                    ref=receipt['build_product']
                    require(artifact(root,ref['path'])==ref, 'stale build product; preserve each mode separately')
                if item['id'].startswith('restart-') or item['id']=='reproducibility':
                    zeroes(item, ('mismatches','missing_fields','nonfinite'))
                    require(count(item.get('fields_checked')) and item['fields_checked']>0
                            and item.get('full_state') is True, 'incomplete restart/reproducibility coverage')
                    if item['id']=='restart-corrupt-truncated':
                        require(item.get('corrupt_rejected') is True and item.get('truncated_rejected') is True
                                and item.get('atomic_rejection') is True, 'checkpoint rejection not verified')
                if item['id']=='releasefast-safety':
                    require(item.get('bounds_checked') is True and item.get('rollback_checked') is True
                            and item.get('allocation_failure_checked') is True, 'missing production safety cases')
                if item['id'].startswith('tests-'):
                    from suite_check import assess
                    suite = referenced(root, item['suite_result'])
                    require(suite.get('case') == item['id'] and not assess(root, suite), 'unassessed/incomplete test suite')
                if item['id'] == 'equivalent-work-performance':
                    from performance_check import check as check_performance
                    performance=check_performance(root,referenced(root,item['benchmark']),binding,source)
                    require(performance['status']=='PASS',performance.get('problem','benchmark failed'))
                    require(type(item.get('repeats')) is int and item['repeats'] >= 3
                            and item.get('equivalent_work') is True, 'performance lacks repeated equivalent work')
                    measurements=item.get('measurements')
                    require(isinstance(measurements,list) and len(measurements)==item['repeats'], 'missing raw performance measurements')
                    for measurement in measurements:
                        for field in ('wall_seconds','cpu_seconds','peak_rss_bytes','accepted_hours'):
                            value=measurement.get(field)
                            require(type(value) in (float,int) and math.isfinite(value) and value>0,
                                    'invalid performance measurement: '+field)
                    require(all(m['accepted_hours']==HOURS for m in measurements), 'performance measurements must cover complete Ottawa')
        return []
    except (OSError, ValueError, KeyError, TypeError, AttributeError, OverflowError, ProtocolError) as exc:
        return [gid + ': ' + str(exc)]

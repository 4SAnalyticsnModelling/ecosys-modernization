"""Validate hash-bound F1–F7 finish evidence; never infer completion from worker exit."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
from workflow import ROOT, artifact, load, inside
from project_runtime import content_digest, SOURCE_SCOPE, git
from qualification_reports import validate as validate_report, referenced


HOURS = 262920

def validate(root: Path = ROOT, certificate: str = '.agent/finish.json') -> list[str]:
    errors = []
    try:
        c = load(inside(root, certificate))
        if c.get('schema_version') != 2:
            errors.append('finish schema 2 required; historical certificates need revalidation')
        source=content_digest(root, SOURCE_SCOPE)
        if c.get('source_digest') != source:
            errors.append('finish source is stale')
        binding = c.get('binding_id')
        if not isinstance(binding, str) or not binding:
            errors.append('missing campaign binding')
        for gid in ['F1','F2','F3','F4','F5','F6','F7']:
            check = c.get('checks', {}).get(gid, {})
            if check.get('source_digest') != source or check.get('binding_id') != binding:
                errors.append(gid + ': source/binding mismatch')
            if check.get('status') != 'PASS' or not check.get('evidence'):
                errors.append(gid + ': missing PASS/evidence'); continue
            for ref in check['evidence']:
                if artifact(root, ref['path']) != ref:
                    errors.append(gid + ': stale artifact ' + ref['path'])
            if gid in ('F2', 'F3', 'F4', 'F5', 'F6'):
                ref = check.get('report')
                if ref not in check['evidence']:
                    errors.append(gid + ': structured report must be hash-bound evidence')
                else:
                    errors.extend(validate_report(root, gid, referenced(root, ref), source, binding))
        frontier = load(root / '.agent/frontier.json')
        if frontier.get('verified_frontier') != HOURS:
            errors.append('strict frontier is not 262920')
        if (frontier.get('evidence_binding') or {}).get('binding_id') != binding:
            errors.append('frontier/certificate bindings differ')
        # F1 structured report must establish terminal hour; prose alone is insufficient.
        campaign = load(inside(root, c['campaign_summary']))
        if not (campaign.get('build_binding_verified') is True and campaign.get('status') == 'COMPLETE' and campaign.get('mode') == 'strict'
                and campaign.get('start_hour') == 0 and campaign.get('last_completed_hour') == HOURS
                and campaign.get('conservation_breaches') == 0
                and campaign.get('solver_fallbacks_unexplained') == 0
                and (campaign.get('binding') or {}).get('binding_id') == binding):
            errors.append('campaign is incomplete, non-strict or unverified')
        if not any(x.get('path') == c['campaign_summary'] for x in c.get('checks', {}).get('F1', {}).get('evidence', [])):
            errors.append('campaign summary is not hash-bound F1 evidence')
        if git(root, 'branch', '--show-current').strip() != b'main':
            errors.append('not on main')
        if git(root, 'status', '--porcelain').strip():
            errors.append('working tree is not clean')
        head = git(root, 'rev-parse', 'HEAD').strip()
        # Query origin rather than trusting a stale remote-tracking ref.
        remote = git(root, 'ls-remote', 'origin', 'refs/heads/main').split()
        if not remote or remote[0] != head:
            errors.append('origin/main differs from HEAD')
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as e:
        errors.append('finish unavailable: ' + str(e))
    except Exception as e:
        errors.append('finish check failed: ' + str(e))
    return errors


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,default=ROOT)
    a=p.parse_args();errors=validate(a.root.resolve());print(json.dumps({'complete':not errors,'problems':errors}))
    return 1 if errors else 0
if __name__ == '__main__':
    raise SystemExit(main())

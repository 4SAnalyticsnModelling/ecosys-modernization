"""Synthetic helper tests only: these do not execute or certify the ecosys model."""
from __future__ import annotations
import copy
import csv
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

PACK=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(PACK))
sys.path.insert(0,str(PACK/'ecosys-audit/scripts'))
import install
import snapshot
import check_gate
import compare_outputs as comparator

class Workspace(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)/'ecosys_modernization'
        self.root.mkdir()
        for name in snapshot.ROOTS:
            (self.root/name).mkdir()
            (self.root/name/'synthetic-fixture.txt').write_text('Synthetic test content, not a model.\n')

class InstallationTests(Workspace):
    def test_dry_run_writes_nothing(self):
        before=sorted(str(x.relative_to(self.root)) for x in self.root.rglob('*'))
        messages=install.install(self.root,PACK,apply=False,mode='copy')
        self.assertTrue(messages[0].startswith('DRY RUN'))
        self.assertEqual(before,sorted(str(x.relative_to(self.root)) for x in self.root.rglob('*')))

    def test_copy_install_preserves_model(self):
        before=snapshot.collect(self.root)
        install.install(self.root,PACK,apply=True,mode='copy')
        self.assertEqual([],snapshot.verify(self.root,before))
        self.assertEqual(16,len(list((self.root/'.claude/skills').glob('*/SKILL.md'))))
        self.assertEqual(16,len(list((self.root/'.agents/skills').glob('*/SKILL.md'))))
        self.assertFalse((self.root/'.pi/skills').exists())

    def test_existing_instruction_prefix_preserved(self):
        original=b'# Existing rules\nNever discard my work.\n'
        (self.root/'AGENTS.md').write_bytes(original)
        install.install(self.root,PACK,apply=True,mode='copy')
        self.assertTrue((self.root/'AGENTS.md').read_bytes().startswith(original))

    def test_empty_existing_instruction_file(self):
        (self.root/'AGENTS.md').touch()
        install.install(self.root,PACK,apply=True,mode='copy')
        self.assertIn(install.BEGIN,(self.root/'AGENTS.md').read_text())

    def test_idempotent(self):
        install.install(self.root,PACK,apply=True,mode='copy')
        original=(self.root/'AGENTS.md').read_bytes()
        result=install.install(self.root,PACK,apply=True,mode='copy')
        self.assertIn('0 additions',result[0])
        self.assertEqual(original,(self.root/'AGENTS.md').read_bytes())

    def test_conflict_preflight_has_no_partial_writes(self):
        target=self.root/'ecosys-audit/PROJECT_CONTRACT.md'
        target.parent.mkdir()
        target.write_text('Existing user content.')
        with self.assertRaises(install.InstallError):
            install.install(self.root,PACK,apply=True,mode='copy')
        self.assertFalse((self.root/'.agents').exists())
        self.assertEqual('Existing user content.',target.read_text())

    def test_missing_project_tree_rejected(self):
        (self.root/'f77src/synthetic-fixture.txt').unlink()
        (self.root/'f77src').rmdir()
        with self.assertRaises(install.InstallError):
            install.install(self.root,PACK,apply=False,mode='copy')

    @unittest.skipIf(os.name=='nt','POSIX symlink test')
    def test_link_install_points_to_canonical(self):
        install.install(self.root,PACK,apply=True,mode='link')
        name='ecosys-release-orchestrator'
        alias=self.root/'.claude/skills'/name
        self.assertTrue(alias.is_symlink())
        self.assertEqual(alias.resolve(),self.root/'.agents/skills'/name)
        self.assertIn('0 additions',install.install(self.root,PACK,apply=True,mode='link')[0])

    @unittest.skipIf(os.name=='nt','POSIX symlink test')
    def test_external_destination_symlink_rejected(self):
        outside=Path(self.temp.name)/'outside'
        outside.mkdir()
        (self.root/'.agents').symlink_to(outside,target_is_directory=True)
        with self.assertRaises(install.InstallError):
            install.install(self.root,PACK,apply=True,mode='copy')
        self.assertFalse(list(outside.iterdir()))

class SnapshotTests(Workspace):
    def test_snapshot_and_unchanged_verification(self):
        record=snapshot.collect(self.root)
        self.assertEqual(4,len(record['files']))
        self.assertEqual([],snapshot.verify(self.root,record))

    def test_edit_and_addition_detected(self):
        record=snapshot.collect(self.root)
        (self.root/'ecosys-ng/synthetic-fixture.txt').write_text('Changed')
        (self.root/'f77src/new.f').write_text('Synthetic')
        issues=snapshot.verify(self.root,record)
        self.assertTrue(any('changed' in x for x in issues))
        self.assertTrue(any('added' in x for x in issues))

    def test_removal_detected(self):
        record=snapshot.collect(self.root)
        (self.root/'f77example/synthetic-fixture.txt').unlink()
        self.assertTrue(any('removed' in x for x in snapshot.verify(self.root,record)))

    def test_caches_excluded_explicitly(self):
        cache=self.root/'ecosys-ng/.zig-cache'
        cache.mkdir()
        (cache/'output').write_text('generated')
        record=snapshot.collect(self.root)
        self.assertEqual(4,len(record['files']))
        self.assertIn('ecosys-ng/.zig-cache',record['excluded_paths'])

    def test_empty_manifest_rejected(self):
        record=snapshot.collect(self.root)
        record['files']=[]
        self.assertTrue(snapshot.verify(self.root,record))

    def test_path_traversal_rejected(self):
        with self.assertRaises(ValueError):
            snapshot.safe_path(self.root,'../outside')

    @unittest.skipIf(os.name=='nt','POSIX symlink test')
    def test_unresolved_input_symlink_rejected(self):
        (self.root/'f77example/linked').symlink_to(self.root/'f77src/synthetic-fixture.txt')
        with self.assertRaises(ValueError):
            snapshot.collect(self.root)

class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.reference=self.root/'reference.csv'
        self.candidate=self.root/'candidate.csv'
        self.schema={'schema_version':1,'status':'APPROVED','approved_by':'Synthetic test reviewer',
                     'keys':['time','cell'],'columns':{
                      'water':{'kind':'number','units':'mm','semantics':'cumulative',
                               'atol':'0.01','rtol':'0.001','scale_floor':'1',
                               'missing_tokens':['NA'],'min_valid_pairs':1,
                               'rationale':'Synthetic fixture tolerance only; not a model threshold.'},
                      'phase':{'kind':'text','semantics':'categorical','missing_tokens':[],
                               'rationale':'Synthetic exact category comparison.'}}}
        self.rows=[['1','a','1.0','liquid'],['2','a','2.0','liquid']]
        self.write(self.reference,self.rows)
        self.write(self.candidate,self.rows)

    def write(self,path,rows,header=None):
        with path.open('w',newline='') as handle:
            writer=csv.writer(handle)
            writer.writerow(header or ['time','cell','water','phase'])
            writer.writerows(rows)

    def run_compare(self):
        return comparator.compare(self.reference,self.candidate,self.schema)

    def test_exact_matches_pass(self):
        result=self.run_compare()
        self.assertEqual('PASS',result['status'])
        self.assertEqual('0.0',result['columns']['water']['max_abs_error'])

    def test_justified_near_tolerance_pass(self):
        self.write(self.candidate,[['1','a','1.005','liquid'],self.rows[1]])
        self.assertEqual('PASS',self.run_compare()['status'])

    def test_numeric_mismatch_fails_with_metrics(self):
        self.write(self.candidate,[['1','a','2.0','liquid'],self.rows[1]])
        result=self.run_compare()
        self.assertEqual('FAIL',result['status'])
        self.assertEqual('0.5',result['columns']['water']['mean_bias'])
        self.assertEqual(1,result['columns']['water']['failed_pairs'])

    def test_exact_category_mismatch_fails(self):
        self.write(self.candidate,[['1','a','1.0','ice'],self.rows[1]])
        self.assertEqual('FAIL',self.run_compare()['status'])

    def test_fortran_d_exponent(self):
        self.write(self.reference,[['1','a','1.0D+00','liquid'],self.rows[1]])
        self.assertEqual('PASS',self.run_compare()['status'])

    def test_nonfinite_rejected(self):
        for token in ['NaN','Inf','-Infinity']:
            with self.subTest(token=token):
                self.write(self.candidate,[['1','a',token,'liquid'],self.rows[1]])
                with self.assertRaises(comparator.ComparisonError):
                    self.run_compare()

    def test_missing_other_side_does_not_hide_nan(self):
        self.write(self.reference,[['1','a','NA','liquid'],self.rows[1]])
        self.write(self.candidate,[['1','a','NaN','liquid'],self.rows[1]])
        with self.assertRaises(comparator.ComparisonError):
            self.run_compare()

    def test_nan_cannot_be_configured_as_missing(self):
        self.schema['columns']['water']['missing_tokens']=['NaN']
        with self.assertRaises(comparator.ComparisonError):
            self.run_compare()

    def test_all_missing_numeric_column_fails(self):
        rows=[['1','a','NA','liquid'],['2','a','NA','liquid']]
        self.write(self.reference,rows)
        self.write(self.candidate,rows)
        self.assertEqual('FAIL',self.run_compare()['status'])

    def test_matched_partial_missing_counted(self):
        rows=[['1','a','NA','liquid'],self.rows[1]]
        self.write(self.reference,rows)
        self.write(self.candidate,rows)
        result=self.run_compare()
        self.assertEqual('PASS',result['status'])
        self.assertEqual(1,result['columns']['water']['both_missing'])

    def test_missingness_mismatch_fails(self):
        self.write(self.candidate,[['1','a','NA','liquid'],self.rows[1]])
        self.assertEqual('FAIL',self.run_compare()['status'])

    def test_duplicate_keys_rejected(self):
        rows=[self.rows[0],self.rows[0]]
        self.write(self.reference,rows)
        self.write(self.candidate,rows)
        with self.assertRaises(comparator.ComparisonError):
            self.run_compare()

    def test_row_count_mismatch_rejected(self):
        self.write(self.candidate,self.rows[:1])
        with self.assertRaises(comparator.ComparisonError):
            self.run_compare()

    def test_misaligned_key_rejected(self):
        self.write(self.candidate,list(reversed(self.rows)))
        with self.assertRaises(comparator.ComparisonError):
            self.run_compare()

    def test_empty_outputs_rejected(self):
        self.write(self.reference,[])
        self.write(self.candidate,[])
        with self.assertRaises(comparator.ComparisonError):
            self.run_compare()

    def test_extra_column_rejected(self):
        self.write(self.candidate,[row+['0'] for row in self.rows],['time','cell','water','phase','hidden'])
        with self.assertRaises(comparator.ComparisonError):
            self.run_compare()

    def test_unapproved_template_rejected(self):
        self.schema['status']='NOT_ASSESSED'
        with self.assertRaises(comparator.ComparisonError):
            self.run_compare()

    def test_negative_tolerance_rejected(self):
        self.schema['columns']['water']['rtol']='-0.01'
        with self.assertRaises(comparator.ComparisonError):
            self.run_compare()

    def test_zero_tolerance_tracks_violation(self):
        self.schema['columns']['water'].update(atol='0',rtol='0')
        self.write(self.candidate,[['1','a','1.001','liquid'],self.rows[1]])
        result=self.run_compare()
        self.assertEqual('FAIL',result['status'])
        self.assertEqual(1,result['columns']['water']['zero_tolerance_violations'])

    def test_cli_nonzero_and_no_report_overwrite(self):
        schema_path=self.root/'schema.json'
        schema_path.write_text(json.dumps(self.schema))
        report_path=self.root/'report.json'
        self.write(self.candidate,[['1','a','8','liquid'],self.rows[1]])
        argv=[sys.executable,str(PACK/'ecosys-audit/scripts/compare_outputs.py'),
              '--reference',str(self.reference),'--candidate',str(self.candidate),
              '--schema',str(schema_path),'--report',str(report_path)]
        result=subprocess.run(argv,capture_output=True,text=True,timeout=10)
        self.assertEqual(1,result.returncode,result.stderr)
        original=report_path.read_bytes()
        again=subprocess.run(argv,capture_output=True,text=True,timeout=10)
        self.assertEqual(2,again.returncode)
        self.assertEqual(original,report_path.read_bytes())

    def test_changed_input_during_comparison_rejected(self):
        with patch.object(comparator,'digest',side_effect=['before-ref','before-new','after-ref']):
            with self.assertRaises(comparator.ComparisonError):
                self.run_compare()

    def test_duplicate_json_schema_key_rejected(self):
        path=self.root/'invalid.json'
        path.write_text('{"status":"APPROVED","status":"NOT_ASSESSED"}')
        with self.assertRaises(comparator.ComparisonError):
            comparator.load_json(path)

class GateTests(Workspace):
    def make_synthetic_gate(self):
        record=snapshot.collect(self.root)
        target=self.root/'audit/manifest/source.json'
        snapshot.write_new_json(target,record)
        evidence=self.root/'audit/synthetic-evidence.txt'
        evidence.write_text('Synthetic bookkeeping test, not scientific/model evidence.\n')
        stage='source-audit'
        return {'schema_version':1,'stage':stage,
                'snapshot':{'path':'audit/manifest/source.json','sha256':snapshot.sha256(target)},
                'checks':[{'id':ident,'status':'PASS','author':'Synthetic author','reviewer':'Synthetic reviewer',
                           'evidence':[{'path':'audit/synthetic-evidence.txt','sha256':snapshot.sha256(evidence)}]}
                          for ident in check_gate.REQUIREMENTS[stage]]}

    def test_synthetic_integrity_record(self):
        self.assertEqual([],check_gate.check(self.root,self.make_synthetic_gate()))

    def test_unassessed_template_blocked(self):
        gate=json.loads((PACK/'ecosys-audit/templates/release.json').read_text())
        self.assertTrue(check_gate.check(self.root,gate))

    def test_changed_source_invalidates_gate(self):
        gate=self.make_synthetic_gate()
        (self.root/'ecosys-ng/synthetic-fixture.txt').write_text('A new candidate.')
        self.assertTrue(any('changed' in item for item in check_gate.check(self.root,gate)))

    def test_new_source_invalidates_gate(self):
        gate=self.make_synthetic_gate()
        (self.root/'ecosys-ng/new.zig').write_text('Synthetic addition')
        self.assertTrue(any('added' in item for item in check_gate.check(self.root,gate)))

    def test_evidence_tampering_detected(self):
        gate=self.make_synthetic_gate()
        (self.root/'audit/synthetic-evidence.txt').write_text('Changed evidence.')
        self.assertTrue(any('hash changed' in item for item in check_gate.check(self.root,gate)))

    def test_self_review_label_rejected(self):
        gate=self.make_synthetic_gate()
        gate['checks'][0]['reviewer']='synthetic AUTHOR'
        self.assertTrue(any('distinct' in item for item in check_gate.check(self.root,gate)))

    def test_missing_check_rejected(self):
        gate=self.make_synthetic_gate()
        gate['checks'].pop()
        self.assertTrue(any('inventory mismatch' in item for item in check_gate.check(self.root,gate)))

    def test_no_evidence_rejected(self):
        gate=self.make_synthetic_gate()
        gate['checks'][0]['evidence']=[]
        self.assertTrue(any('no evidence' in item for item in check_gate.check(self.root,gate)))

class SkillStructureTests(unittest.TestCase):
    def test_all_portable_skill_headers_and_references(self):
        files=list((PACK/'.agents/skills').glob('*/SKILL.md'))
        self.assertEqual(16,len(files))
        for path in files:
            text=path.read_text(encoding='utf-8')
            self.assertTrue(text.startswith('---\n'))
            front=text.split('---',2)[1]
            fields=dict(line.split(': ',1) for line in front.strip().splitlines())
            name=fields['name']
            description=json.loads(fields['description'])
            self.assertEqual(name,path.parent.name)
            self.assertRegex(name,r'^[a-z0-9]+(?:-[a-z0-9]+)*$')
            self.assertLessEqual(len(name),64)
            self.assertTrue(0<len(description)<=1024)
            self.assertLess(len(text.splitlines()),500)
            for required in ['PROJECT_CONTRACT.md','EVIDENCE_GUIDE.md','SOURCES.md']:
                self.assertIn(required,text)
                self.assertTrue((PACK/'ecosys-audit'/required).is_file())

if __name__=='__main__':
    unittest.main()

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const {notes,verifySummary}=await import(process.env.NOTES_CORE_UNDER_TEST
  ? pathToFileURL(process.env.NOTES_CORE_UNDER_TEST) : new URL('../core.mjs',import.meta.url));

function fixture(t,overrides={}) {
  const base=path.resolve(import.meta.dirname,'../../../.tmp');
  fs.mkdirSync(base,{recursive:true});
  const root=fs.mkdtempSync(path.join(base,'notes-recovery-'));
  t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const files={'progress.md':'Verified current cycle.\n','decisions.md':'Keep scientific gates unchanged.\n',
    'issues.md':'Unresolved hypothesis; inspect evidence.\n',...overrides};
  for (const [file,text] of Object.entries(files)) fs.writeFileSync(path.join(root,file),text);
  return {root,files};
}

test('oversized progress preserves complete originals and permits the curation turn',t=>{
  const f=fixture(t,{'progress.md':'Historical verified progress.\n'.repeat(1000)+'CURRENT CYCLE NEXT ACTION\n'});
  const memory=notes(f.root);
  assert.ok(Buffer.byteLength(memory.text)<=24000);
  assert.match(memory.text,/CURRENT CYCLE NEXT ACTION/);
  assert.ok(memory.text.includes(f.files['decisions.md']));
  assert.ok(memory.text.includes(f.files['issues.md']));
  assert.match(memory.text,/may omit older lines, including decisions/);
  assert.deepEqual(JSON.parse(fs.readFileSync(memory.archive,'utf8')).files,f.files);
  for (const [file,text] of Object.entries(f.files)) assert.equal(fs.readFileSync(path.join(f.root,file),'utf8'),text);
  assert.deepEqual(notes(f.root),memory);
  assert.equal(fs.readdirSync(path.join(f.root,'notes-archive')).length,1);
  const result=verifySummary({summary:[{type:'text',text:'Evidence-backed summary. '.repeat(8)}]},memory,'cp');
  assert.ok(result.summary[0].text.includes(memory.text));
});

test('all large notes use whole UTF-8 lines, with complete text recoverable',t=>{
  const f=fixture(t,Object.fromEntries(['progress.md','decisions.md','issues.md'].map(file=>
    [file,('🌲 Verified line in '+file+'\n').repeat(1100)+'LATEST '+file+'\n'])));
  const memory=notes(f.root);
  assert.ok(Buffer.byteLength(memory.text)<=24000);
  assert.ok(!memory.text.includes('\ufffd'));
  for (const file of Object.keys(f.files)) assert.ok(memory.text.includes('LATEST '+file));
  assert.deepEqual(JSON.parse(fs.readFileSync(memory.archive,'utf8')).files,f.files);
});

test('single enormous lines remain in the archive without invented partial statements',t=>{
  const f=fixture(t,{'progress.md':'🌲'.repeat(10000)});
  const memory=notes(f.root);
  assert.ok(Buffer.byteLength(memory.text)<=24000);
  assert.ok(!memory.text.includes('🌲'));
  assert.equal(JSON.parse(fs.readFileSync(memory.archive,'utf8')).files['progress.md'],f.files['progress.md']);
});

test('changes outside the visible tail change the checkpoint hash and retain both archives',t=>{
  const f=fixture(t,{'progress.md':'Old fact A\n'+'Retained recent progress.\n'.repeat(1200)});
  const before=notes(f.root);
  fs.writeFileSync(path.join(f.root,'progress.md'),f.files['progress.md'].replace('fact A','fact B'));
  const after=notes(f.root);
  assert.notEqual(before.hash,after.hash);
  assert.notEqual(before.archive,after.archive);
  assert.equal(fs.readdirSync(path.join(f.root,'notes-archive')).length,2);
});

test('hidden conflicts and corrupt archives still fail closed',t=>{
  const f=fixture(t,{'progress.md':'CONFLICT: unresolved\n'+'Old progress.\n'.repeat(2500)});
  assert.throws(()=>notes(f.root),/decision conflict/);
  fs.writeFileSync(path.join(f.root,'progress.md'),f.files['progress.md'].replace('CONFLICT:','RESOLVED:'));
  const memory=notes(f.root);
  fs.writeFileSync(memory.archive,'{}');
  assert.throws(()=>notes(f.root),/archive mismatch/);
});

test('failed archival cannot silently admit a truncated checkpoint',t=>{
  const f=fixture(t,{'progress.md':'Old progress.\n'.repeat(2500)});
  fs.writeFileSync(path.join(f.root,'notes-archive'),'blocked directory');
  assert.throws(()=>notes(f.root));
  assert.equal(fs.readFileSync(path.join(f.root,'progress.md'),'utf8'),f.files['progress.md']);
});

test('small notes retain their exact existing representation',t=>{
  const f=fixture(t);
  const memory=notes(f.root);
  assert.equal(memory.text,Object.entries(f.files).map(([file,text])=>`### ${file}\n${text}`).join('\n'));
  assert.equal(memory.archive,undefined);
  assert.ok(!fs.existsSync(path.join(f.root,'notes-archive')));
});

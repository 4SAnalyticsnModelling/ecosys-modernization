// One-time evidence-bound repair; never reset or replace native session history.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
import {atomic,syncTree,readState} from '../../../tools/dsh-watchdog/core.mjs';

const repo=process.cwd();
const instance=path.resolve('.dsh-watchdog/instances/8275edde-5f78-4615-89d6-f02a66cc8361');
const root=path.join(instance,'agents/dc1a19c0d0843dc600815c3cac54868bd89920e087459d740c26be23cd8020eb');
const id='4c83caf2-c5bc-4235-81c5-f346a4f7f22a';
const stateFile=path.join(root,'state.json');
const state=readState(stateFile),record=state.sessions[id];
assert.equal(record.phase,'compacting');
assert.equal(record.checkpoint,'5578a3c4-7891-4922-bba5-711c59154e08');
const checkpoint=path.join(root,'checkpoints',record.checkpoint);
assert.ok(!fs.existsSync(path.join(checkpoint,'completed.json')));
const receipt=JSON.parse(fs.readFileSync(path.join(checkpoint,'receipt.json'),'utf8'));
assert.equal(receipt.sessionId,id);
assert.equal(receipt.checkpoint,record.checkpoint);
const runtime=path.join(os.homedir(),'.local/share/deepseek-harness/runtime/node_modules/@deepseek-ai');
const {Context}=await import(pathToFileURL(path.join(runtime,'cordis/lib/index.js')));
const {default:Backend}=await import(pathToFileURL(path.join(runtime,'dsh-session-persistence-jsonl/lib/index.js')));
const contexts=[new Context(),new Context()],handles=[];
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
try {
  // Native write ownership acquires the real cross-process session lease.
  handles.push(await new Backend(contexts[0],{root:path.join(instance,'sessions')}).open(id,'write'));
  handles.push(await new Backend(contexts[1],{root:path.join(checkpoint,'sessions')}).open(id,'read'));
  const [live,saved]=await Promise.all(handles.map(h=>h.read()));
  const a=live.events,b=saved.events,start=a.at(-1);
  assert.equal(a.length,b.length+1);
  assert.deepEqual(a.slice(0,-1),b);
  assert.equal(start.type,'compaction/start');
  assert.equal(start.seq,5103);
  assert.equal(start.data.turn,5);
  assert.equal(start.data.compactionId,'e2d0bdd5-7727-4635-a0b2-074b95b7fd82');
  const maintenance=path.resolve('.dsh-watchdog/maintenance/notes-size-recovery-20261022');
  const nativeFile=path.join(instance,'sessions/--Users-4sanalyticsnmodelling-Documents-ecosys-modernization--',id,'session.v4.jsonl.zstd');
  const backup=path.join(maintenance,'interrupted-before.v4.jsonl.zstd');
  fs.copyFileSync(nativeFile,backup,fs.constants.COPYFILE_EXCL);
  atomic(path.join(maintenance,'interrupted-state.before.json'),state);
  syncTree(maintenance);
  const reason='Owner exited during uncommitted compaction; complete original event prefix verified unchanged against the saved checkpoint. No summary was published.';
  const appended=[
    {type:'compaction/end',seq:start.seq+1,time:Date.now(),data:{...start.data,error:reason}},
    {type:'turn/end',seq:start.seq+2,time:Date.now(),data:{turn:5,reason:{kind:'error',error:{code:'INTERRUPTED_BEFORE_PUBLICATION',message:reason}}}}
  ];
  const report={status:'PREPARED',sessionId:id,checkpoint:record.checkpoint,
    preservedPrefixEvents:a.length,checkpointPrefixEvents:b.length,unchangedCheckpointPrefix:true,
    noSummaryPublication:true,backup:path.relative(repo,backup),backupSha256:hash(fs.readFileSync(backup)),appended};
  atomic(path.join(checkpoint,'reconciliation.json'),report);
  await handles[0].append(appended);
  await handles[0].flush();
  const after=(await handles[0].read()).events;
  assert.deepEqual(after.slice(0,a.length),a);
  assert.deepEqual(after.slice(a.length),appended);
  report.status='RECONCILED_UNPUBLISHED';
  report.sessionAfterSha256=hash(fs.readFileSync(nativeFile));
  atomic(path.join(checkpoint,'reconciliation.json'),report);
  // This is permission to retry native balanced compaction, not a successful boundary.
  state.sessions[id]={...record,phase:'running',error:null,taskActive:true,recoveryPending:true,
    recoveryReason:'INTERRUPTED_BEFORE_PUBLICATION',reconciledCheckpoint:record.checkpoint,
    updatedAt:new Date().toISOString()};
  atomic(stateFile,state);
  atomic(path.resolve('audit/reviews/notes-size-recovery-20261022/interrupted-reconciliation.json'),report);
  console.log(JSON.stringify({status:report.status,preservedEvents:a.length,appendedEvents:appended.length}));
} finally {
  for (const handle of handles) await handle.close();
  for (const context of contexts) await context.fiber.dispose();
}

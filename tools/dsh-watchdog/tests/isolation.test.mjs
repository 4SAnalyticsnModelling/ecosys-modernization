import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {atomic,readState} from '../core.mjs';
import {sessionRoot,snapshotSession} from '../session-paths.mjs';
import {apply as transport} from '../transport.mjs';
import {apply as execution} from '../execution-isolation.mjs';
const repo=path.resolve(import.meta.dirname,'../../..');
function fixture(){const root=fs.mkdtempSync(path.join(repo,'.tmp/session-isolation-'));atomic(path.join(root,'state.json'),{schema:1,sessions:{},layout:'per-agent-v1'});return root;}

test('same-model native sessions and nested agents own independent notes/state',()=>{
 const base=fixture(),a=sessionRoot(base,'same-model-a'),b=sessionRoot(base,'same-model-b'),child=sessionRoot(base,'child-of-a');
 assert.equal(new Set([a,b,child]).size,3);
 fs.writeFileSync(path.join(a,'decisions.md'),'PRIVATE A');
 atomic(path.join(a,'state.json'),{schema:1,sessions:{'same-model-a':{phase:'blocked',checkpoint:'A'}}});
 assert.equal(readState(path.join(b,'state.json')).sessions['same-model-a'],undefined);
 assert.ok(!fs.readFileSync(path.join(child,'decisions.md'),'utf8').includes('PRIVATE A'));
 assert.equal(sessionRoot(base,'same-model-a'),a);
 assert.equal(sessionRoot(base,'../../escape'),path.join(base,'agents',path.basename(sessionRoot(base,'../../escape'))));
});
test('corrupt session state fails without replacing or blocking siblings',()=>{
 const base=fixture(),a=sessionRoot(base,'a'),b=sessionRoot(base,'b');
 fs.writeFileSync(path.join(a,'state.json'),'{');
 assert.throws(()=>sessionRoot(base,'a'));
 assert.equal(fs.readFileSync(path.join(a,'state.json'),'utf8'),'{');
 assert.equal(sessionRoot(base,'b'),b);
});
test('checkpoints retain native project layout and exclude siblings',async()=>{
 const base=fixture();
 for(const id of ['a','b']){const d=path.join(base,'sessions/project',id);fs.mkdirSync(d,{recursive:true});fs.writeFileSync(path.join(d,'session.v4.jsonl'),id);}
 const target=path.join(base,'snapshot');
 await snapshotSession(base,'a',target,{resolveCurrentLog:async()=>path.join(base,'sessions/project/a/session.v4.jsonl')});
 assert.equal(fs.readFileSync(path.join(target,'project/a/session.v4.jsonl'),'utf8'),'a');
 assert.ok(!fs.existsSync(path.join(target,'project/b')));
 await assert.rejects(snapshotSession(base,'a',target,{resolveCurrentLog:async()=>'/outside/session/log'}),/escapes/);
});
test('concurrent streams of same model carry distinct native session identities',async()=>{
 const previous=globalThis.fetch,endpoint=process.env.DSH_ISOLATED_ENDPOINT;
 process.env.DSH_ISOLATED_ENDPOINT='http://127.0.0.1:12345';
 const calls=[],cleanups=[];let listener;
 globalThis.fetch=async(_input,init)=>{calls.push(Object.fromEntries(init.headers));return {};};
 transport({effect:fn=>cleanups.push(fn()),on:(_name,fn)=>{listener=fn;}});
 try{
  const run=async id=>{
   const stream=listener({provider:'mlx-local',sessionId:id,purpose:id==='a'?'compaction':undefined},()=>({async *[Symbol.asyncIterator](){await Promise.resolve();await fetch('http://127.0.0.1:12345/v1/chat/completions');yield id;}}));
   for await(const value of stream)assert.equal(value,id);
  };
  await Promise.all([run('a'),run('b')]);
  assert.deepEqual(calls.map(c=>c['x-dsh-session']).sort(),['a','b']);
  assert.equal(calls.find(c=>c['x-dsh-session']==='a')['x-dsh-purpose'],'compaction');
 }finally{for(const clean of cleanups)clean();globalThis.fetch=previous;if(endpoint===undefined)delete process.env.DSH_ISOLATED_ENDPOINT;else process.env.DSH_ISOLATED_ENDPOINT=endpoint;}
});
test('concurrent agent shell calls get separate managed roots and caches',async()=>{
 const base=fixture(),old=process.env.DSH_WATCHDOG_ROOT;process.env.DSH_WATCHDOG_ROOT=base;
 let hook,contributor;
 const ctx={shell:{resolve:request=>request},shellEnv:{register:value=>{contributor=value;}},on:(_name,fn)=>{hook=fn;},inject:()=>{}};
 execution(ctx);
 try{
  const run=id=>hook({agent:{session:{id}}},async()=>{await Promise.resolve();return {request:ctx.shell.resolve({command:'true'}),managed:contributor.resolve({agent:{session:{id}}})};});
  const [a,b]=await Promise.all([run('a'),run('b')]);
  assert.notEqual(a.request.env.TMPDIR,b.request.env.TMPDIR);
  assert.notEqual(a.managed.DSH_WATCHDOG_ROOT,b.managed.DSH_WATCHDOG_ROOT);
  assert.ok(a.request.env.TMPDIR.startsWith(a.managed.DSH_WATCHDOG_ROOT+path.sep));
  assert.equal(a.managed.DSH_WATCHDOG_LAUNCH_ROOT,base);
 }finally{if(old===undefined)delete process.env.DSH_WATCHDOG_ROOT;else process.env.DSH_WATCHDOG_ROOT=old;}
});

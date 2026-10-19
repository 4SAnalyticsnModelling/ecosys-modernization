import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {pathToFileURL} from 'node:url';
import {policy,LIMIT,WINDOW,OUTPUT,HEADROOM,hygiene,validateRoute,atomic,readState,notes,verifySummary,repeatCount,snapshotWorktree} from '../core.mjs';
const repo = path.resolve(import.meta.dirname,'../../..');
const runtime = process.env.DSH_WATCHDOG_RUNTIME ?? path.join(os.homedir(),'.local/share/deepseek-harness/runtime');
process.env.DSH_WATCHDOG_RUNTIME = runtime;
async function installed(name) { return import(pathToFileURL(path.join(runtime,'node_modules/@deepseek-ai',name,'lib/index.js'))); }
const {Context} = await installed('cordis');
const {default:LlmRuntime,LlmAdapter,createUserMessage,createMessage,createToolResultMessage} = await installed('dsh-llm');
const {default:SessionStore,Session,SessionId} = await installed('dsh-session');
const {default:Projections} = await installed('dsh-session-projection');
const {default:TokenMeter} = await installed('dsh-token-meter');
const {default:Pruner} = await import('../hygiene.mjs');
const {AgentRegistry} = await installed('dsh-agent');
const {default:Watchdog} = await import('../plugin.mjs');
const signal = new AbortController().signal;

function fixture() {
  const dir = fs.mkdtempSync(path.join(repo,'.tmp/dsh-test-'));
  process.env.DSH_WATCHDOG_ROOT = dir;
  fs.mkdirSync(path.join(dir,'sessions'));
  atomic(path.join(dir,'state.json'),{schema:1,sessions:{}});
  for (const f of ['progress.md','decisions.md','issues.md']) fs.copyFileSync(path.join(repo,'tools/dsh-watchdog/templates',f),path.join(dir,f));
  const ctx = new Context();
  new LlmRuntime(ctx); new SessionStore(ctx); new Projections(ctx); new TokenMeter(ctx); new Pruner(ctx,hygiene); new AgentRegistry(ctx);
  class Adapter extends LlmAdapter {
    async resolveModel(provider,model) { return {provider,id:model,name:model,context:{contextWindow:WINDOW},defaultMaxTokens:OUTPUT}; }
    async *stream() { yield {type:'finish',reason:{kind:'stop'}}; }
  }
  ctx.llm.registerAdapter(['mlx-local'],new Adapter());
  const session = ctx.sessions.create(SessionId('test-session'));
  ctx.on('session/flush', s=>{ fs.writeFileSync(path.join(dir,'sessions','test.json'), JSON.stringify({seq:s.seq})); });
  const agent = {session,options:{provider:'mlx-local',model:'test'}};
  ctx.agents.get = id => id === session.id ? agent : undefined;
  ctx.agents.roots = () => [agent];
  const compact = new Watchdog(ctx);
  const seedText = 'Important scientific decision and file reference. '.repeat(850);
  for (let turn=1;turn<=4;turn++) {
    session.append('turn/start',{turn});
    session.append('user/message',createUserMessage({content:[{type:'text',text:seedText}],source:{kind:'user'}}),{surfaceOp:'append'});
    session.append('step/start',{turn,step:1});
    if (turn===1) session.append('request/header',{header:{config:{provider:'mlx-local',model:'test',maxTokens:OUTPUT}},reason:'initial'});
    session.append('assistant/message',{stream:[],turn,step:1,message:createMessage({role:'assistant',content:[{type:'text',text:seedText}],source:{kind:'model',provider:'mlx-local',model:'test'}})},{surfaceOp:'append'});
    session.append('step/end',{turn,step:1});
    session.append('turn/end',{turn,reason:{kind:'completed'}});
  }
  session.append('turn/start',{turn:5});
  // Summarizer uses deterministic fixture only; native engine still chooses
  // region, validates stable surface/shrink, appends brackets and commits.
  let calls=0;
  compact.summarize = async () => {
    calls++;
    return verifySummary({summary:[{type:'text',text:'Verified scientific checkpoint. Preserve mineral N conservation and all completed tests; next inspect the exact binding. '.repeat(3)}],provider:'mlx-local',model:'test',maxTokens:4096}, notes(dir),compact.record(agent).checkpoint);
  };
  return {ctx,agent,compact,dir,calls:()=>calls};
}

test('exact trigger formula for every valid output reservation',()=> {
  for (let output=1;output<=OUTPUT;output++) validateRoute(WINDOW,output);
  assert.equal(Math.floor(Math.min(WINDOW*policy.thresholdRatio,WINDOW-OUTPUT-HEADROOM)),LIMIT);
  assert.throws(()=>validateRoute(65536,OUTPUT));
  assert.throws(()=>validateRoute(WINDOW,65536));
});

test('native token-cap exhaustion commits a complete archived recovery checkpoint',async()=> {
  const f=fixture();
  f.compact.summarize=Watchdog.prototype.summarize.bind(f.compact);
  let calls=0;
  f.ctx.llm.stream=()=>({async *[Symbol.asyncIterator]() {
    calls++;
    yield {type:'finish',reason:{kind:'max-tokens'}};
  }});
  const meter=f.ctx.tokenMeter.measure.bind(f.ctx.tokenMeter);
  const generation=f.agent.session.surface.replaceGeneration;
  f.ctx.tokenMeter.measure=(...args)=>({...meter(...args),totalTokens:f.agent.session.surface.replaceGeneration===generation ? 75001 : 20000});
  const result=await f.compact.compactIfNeeded(f.agent,'pressure',signal);
  assert.ok(result);assert.equal(calls,1);
  assert.equal(f.compact.record(f.agent).phase,'running');
  assert.equal(f.compact.record(f.agent).summaryFallbacks,1);
  const dir=path.join(f.dir,'checkpoints',f.compact.record(f.agent).checkpoint);
  assert.ok(fs.existsSync(path.join(dir,'completed.json')));
  assert.ok(JSON.parse(fs.readFileSync(path.join(dir,'summary-input.json'))).messages.length>0);
  assert.ok(f.agent.session.snapshotEvents().some(e=>e.type==='compaction/end' && !e.data.error));
  await f.ctx.fiber.dispose();
});

test('only a closed pre-commit summary failure reconciles automatically',async()=> {
  const f=fixture();
  const checkpoint='closed-summary';
  const dir=path.join(f.dir,'checkpoints',checkpoint);
  fs.mkdirSync(path.join(dir,'sessions'),{recursive:true});
  atomic(path.join(dir,'receipt.json'),{checkpoint,sessionId:f.agent.session.id});
  const message='summarization truncated at the token cap (incomplete checkpoint)';
  const start=f.agent.session.append('compaction/start',{compactionId:'failed',turn:5});
  f.compact.update(f.agent,{phase:'blocked',checkpoint,error:'Error: '+message});
  assert.equal(f.compact.reconcileSummaryFailure(f.agent),false);
  f.agent.session.append('compaction/end',{compactionId:'failed',turn:5,error:message});
  assert.equal(f.compact.reconcileSummaryFailure(f.agent),true);
  assert.equal(f.compact.record(f.agent).recoveryPending,true);
  assert.equal(JSON.parse(fs.readFileSync(path.join(dir,'reconciliation.json'))).startSeq,start.seq);
  f.compact.update(f.agent,{phase:'blocked',error:'Error: disk unavailable'});
  assert.equal(f.compact.reconcileSummaryFailure(f.agent),false);
  await f.ctx.fiber.dispose();
});

test('74K does not compact; 75K causes one native balanced compaction',async()=> {
  const f=fixture();
  const realMeasure=f.ctx.tokenMeter.measure.bind(f.ctx.tokenMeter);
  let boundary=74000;
  f.ctx.tokenMeter.measure=(...args)=> {
    const m=realMeasure(...args);
    return {...m,totalTokens:f.calls() ? m.totalTokens : boundary};
  };
  assert.equal(await f.compact.compactIfNeeded(f.agent,'pressure',signal),null);
  assert.equal(f.calls(),0);
  boundary=75000;
  const result=await f.compact.compactIfNeeded(f.agent,'pressure',signal);
  assert.ok(result); assert.equal(f.calls(),1);
  assert.equal(f.compact.record(f.agent).compactions,1);
  assert.ok(f.compact.record(f.agent).capacitySafe === true);
  const checkpoint=f.compact.record(f.agent).checkpoint;
  assert.ok(fs.existsSync(path.join(f.dir,'checkpoints',checkpoint,'worktree.patch')));
  assert.equal(await f.compact.compactIfNeeded(f.agent,'pressure',signal),null);
  assert.equal(f.calls(),1);
  await f.ctx.fiber.dispose();
});

test('failed native summary preserves original surface and blocks restart',async()=> {
  const f=fixture();
  const meter=f.ctx.tokenMeter.measure.bind(f.ctx.tokenMeter);
  f.ctx.tokenMeter.measure=(...args)=>({...meter(...args),totalTokens:75000});
  f.compact.summarize=async()=>{throw Error('summary unavailable');};
  const generation=f.agent.session.surface.replaceGeneration;
  await assert.rejects(f.compact.compactIfNeeded(f.agent,'pressure',signal),/summary unavailable/);
  assert.equal(f.agent.session.surface.replaceGeneration,generation);
  assert.equal(readState(path.join(f.dir,'state.json')).sessions[f.agent.session.id].phase,'blocked');
  await f.ctx.fiber.dispose();
});

test('missing meter never silently permits request',()=> {
  assert.throws(()=>Watchdog.prototype.measure.call({ctx:{}},{session:{}}),/token meter/);
});

test('mounted watchdog dependencies permit meter access in a restricted plugin context',async()=> {
  const ctx=new Context();
  // Services must come from a sibling mounted plugin, as in production. Root
  // providers bypass Cordis injection checks and hid this startup failure.
  await ctx.plugin({apply(provider) {
    for (const name of ['llm','sessions','agents','sessionPersistence']) provider.provide(name,{});
    provider.provide('tokenMeter',{measure:()=>({totalTokens:123})});
  }});
  let measured;
  class MountedProbe {
    static inject=Watchdog.inject;
    constructor(ctx) { measured=Watchdog.prototype.measure.call({ctx},{session:{}}); }
  }
  try {
    await ctx.plugin(MountedProbe);
    assert.equal(measured.totalTokens,123);
  } finally {
    await ctx.fiber.dispose();
  }
});

test('durable notes are retained verbatim; conflicts and failed summary reject',()=> {
  const f=fixture();
  const memory=notes(f.dir);
  assert.ok(verifySummary({summary:[{type:'text',text:'x'.repeat(100)}]},memory,'cp1').summary[0].text.includes(memory.text));
  assert.throws(()=>verifySummary({summary:[]},memory,'cp1'),/summary/);
  fs.appendFileSync(path.join(f.dir,'decisions.md'),'\nCONFLICT: scientific bound differs\n');
  assert.throws(()=>notes(f.dir),/conflict/);
});

test('atomic state survives reload; corrupt state fails closed',()=> {
  const f=fixture(), file=path.join(f.dir,'state.json');
  atomic(file,{schema:1,sessions:{s:{checkpoint:'cp1',phase:'compacting'}}});
  assert.equal(readState(file).sessions.s.checkpoint,'cp1');
  fs.writeFileSync(file,'{'); assert.throws(()=>readState(file));
});

test('operation repeat counters do not depend on call identifiers',()=> {
  let previous;
  for(let i=1;i<=8;i++) {
    const signature=JSON.stringify({name:'bash',arguments:'same command'});
    previous={signature,count:repeatCount(previous,signature)};
    assert.equal(previous.count,i);
  }
});

test('confirmed overflow can compact below normal boundary',async()=> {
  const f=fixture();
  const result=await f.compact.compactIfNeeded(f.agent,'context-overflow',signal);
  assert.ok(result); assert.equal(f.calls(),1);
  assert.equal(f.compact.record(f.agent).trigger,'context-overflow');
  await f.ctx.fiber.dispose();
});


test('fully assembled request catches late admission and supported retry rebuilds',async()=> {
  const f=fixture();
  const meter=f.ctx.tokenMeter.measure.bind(f.ctx.tokenMeter);
  f.ctx.tokenMeter.measure=(...args)=>({...meter(...args),totalTokens:f.calls() ? meter(...args).totalTokens : 75000});
  const chunks=await Array.fromAsync(f.ctx.llm.stream({provider:'mlx-local',model:'test',sessionId:f.agent.session.id,maxTokens:OUTPUT,messages:[]}));
  assert.equal(chunks.at(-1).reason.failure.code,'WATCHDOG_BOUNDARY');
  const action=await f.ctx.waterfall('agent/request-error',{agent:f.agent,failure:chunks.at(-1).reason.failure,signal},()=>undefined);
  assert.equal(action.kind,'retry');
  assert.equal(f.calls(),1);
  const resumed=await Array.fromAsync(f.ctx.llm.stream({provider:'mlx-local',model:'test',sessionId:f.agent.session.id,maxTokens:OUTPUT,messages:[]}));
  assert.equal(resumed.at(-1).reason.kind,'stop');
  await f.ctx.fiber.dispose();
});

test('eight repeated tool operations block despite changing turn, step and callId',async()=> {
  const f=fixture();
  for(let i=1;i<=8;i++) f.agent.session.append('tool/call',{turn:5,step:i,callId:'call-'+i,name:'bash',arguments:'{"command":"rg unchanged"}'});
  assert.equal(f.compact.record(f.agent).toolLoop.count,8);
  assert.notEqual(f.compact.record(f.agent).phase,'blocked');
  await f.ctx.fiber.dispose();
});

test('successful assistant resets consecutive failure and overflow counters',async()=> {
  const f=fixture();
  f.compact.update(f.agent,{overflowRetries:1,failure:{signature:'error',count:2}});
  f.agent.session.append('assistant/message',{stream:[],turn:5,step:1,message:createMessage({role:'assistant',content:[{type:'text',text:'successful result'}],source:{kind:'model',provider:'mlx-local',model:'test'}})},{surfaceOp:'append'});
  assert.equal(f.compact.record(f.agent).overflowRetries,0);
  assert.equal(f.compact.record(f.agent).failure,null);
  await f.ctx.fiber.dispose();
});

test('known interrupted task queues a durable-notes continuation through agent service',async()=> {
  const f=fixture(); let continuation;
  f.compact.update(f.agent,{phase:'running',lastFinish:'stop',taskActive:true});
  process.env.DSH_WATCHDOG_AUTO_RESUME='1';
  f.agent.followup = message=>{continuation=message;};
  await f.ctx.serial('agent/created',{agent:f.agent,source:'resume'});
  assert.ok(continuation.content[0].text.includes('Verify outcomes of interrupted tools'));
  assert.equal(f.compact.record(f.agent).resumptions,1);
  await f.ctx.fiber.dispose();
});


test('subagent telemetry cannot replace the root resume pointer',async()=> {
  const f=fixture();
  f.compact.update(f.agent,{phase:'running'});
  const child={session:{id:'child-session'}};
  f.compact.update(child,{phase:'running'});
  const state=readState(path.join(f.dir,'state.json'));
  assert.equal(state.currentSession,f.agent.session.id);
  assert.equal(state.sessions['child-session'].phase,'running');
  await f.ctx.fiber.dispose();
});


test('non-Git workspace snapshots source without recursively copying watchdog state',async()=> {
  const root=fs.mkdtempSync(path.join(repo,'.tmp/nongit-'));
  fs.writeFileSync(path.join(root,'.git'),'invalid git pointer\n'); // prevent discovery of the parent test repository
  fs.writeFileSync(path.join(root,'source.txt'),'verified decision and source');
  const wd=path.join(root,'.dsh-watchdog'), cp=path.join(wd,'checkpoints','cp1');
  fs.mkdirSync(cp,{recursive:true});fs.writeFileSync(path.join(wd,'state.json'),'private');
  await snapshotWorktree(cp,root,wd);
  assert.equal(fs.readFileSync(path.join(cp,'untracked/source.txt'),'utf8'),'verified decision and source');
  assert.ok(!fs.existsSync(path.join(cp,'untracked/.dsh-watchdog')));
});

test('unborn Git repository checkpoints staged and untracked source',async()=> {
  const {execFileSync}=await import('node:child_process');
  const root=fs.mkdtempSync(path.join(repo,'.tmp/unborn-'));
  execFileSync('git',['init','-q'],{cwd:root});
  fs.writeFileSync(path.join(root,'source.txt'),'staged code');
  execFileSync('git',['add','source.txt'],{cwd:root});
  const wd=path.join(root,'.dsh-watchdog'), cp=path.join(wd,'checkpoints','cp1');
  fs.mkdirSync(cp,{recursive:true});fs.writeFileSync(path.join(wd,'state.json'),'private');
  await snapshotWorktree(cp,root,wd);
  assert.ok(fs.readFileSync(path.join(cp,'worktree.patch'),'utf8').includes('staged code'));
  assert.ok(!fs.existsSync(path.join(cp,'untracked/.dsh-watchdog')));
});

function appendVerboseError(f) {
  f.agent.session.append('step/start',{turn:5,step:1});
  const callId='read-diagnostic';
  const original='ERROR: failed binding\n'+'diagnostic detail '.repeat(400)+'\nSOURCE: /project/full-test.log:45\n'+'middle data '.repeat(400)+'\nEND: exit=1';
  f.agent.session.append('assistant/message',{stream:[],turn:5,step:1,message:createMessage({role:'assistant',
    content:[{type:'tool-call',id:callId,name:'read',arguments:'{"path":"full-test.log"}'}],
    source:{kind:'model',provider:'mlx-local',model:'test'}})},{surfaceOp:'append'});
  f.agent.session.append('tool/call',{turn:5,step:1,callId,name:'read',arguments:'{"path":"full-test.log"}'});
  const event=f.agent.session.append('tool/result',{turn:5,step:1,
    message:createToolResultMessage({callId,isError:true,content:[{type:'text',text:original}]}),
    error:{name:'DiagnosticError',code:'BINDING_FAILURE',reason:'Check /project/full-test.log:45'},
    meta:{fullLog:'/project/full-test.log',exitCode:1}},{surfaceOp:'append'});
  return {event,original,callId};
}

test('continuous hygiene below75K retains errors, originals, pairing, index and replay',async()=> {
  const f=fixture(), {event,original,callId}=appendVerboseError(f);
  const file=path.join(f.dir,'sessions','native.jsonl');
  f.ctx.on('session/flush', session=>fs.writeFileSync(file,session.snapshotEvents().map(e=>JSON.stringify(e)).join('\n')));
  const result=await f.compact.cleanToolOutputs(f.agent);
  assert.equal(result.pruned.length,1);assert.equal(f.calls(),0);
  const entries=fs.readFileSync(file,'utf8').split('\n').map(x=>JSON.parse(x));
  const originalEvent=entries.find(e=>e.seq===event.seq);
  assert.equal(originalEvent.data.message.content[0].text,original);
  const replacement=entries.find(e=>e.seq===result.pruned[0].replacementSeq);
  assert.equal(replacement.data.message.source.callId,callId);
  assert.equal(replacement.data.message.isError,true);
  assert.deepEqual(replacement.data.error,event.data.error);
  assert.deepEqual(replacement.data.meta,event.data.meta);
  assert.ok(replacement.sourceEventSeqs.includes(event.seq));
  const text=replacement.data.message.content.map(b=>b.text ?? '').join('');
  assert.ok(text.includes('hygiene-index.jsonl'));assert.ok(text.includes('ERROR:'));assert.ok(text.includes('exit=1'));
  assert.ok(Array.from(text).length<=hygiene.thresholdChars);
  const replay=Session.create(SessionId('replayed-hygiene'),entries);
  assert.deepEqual(replay.surface.nodes,f.agent.session.surface.nodes);
  const again=await f.compact.cleanToolOutputs(f.agent);assert.equal(again.pruned.length,0);
  assert.equal(f.compact.record(f.agent).hygienePrunes,1);
  const index=JSON.parse(fs.readFileSync(path.join(f.dir,'hygiene-index.jsonl'),'utf8'));
  assert.equal(index.callId,callId);assert.equal(index.originalSeq,event.seq);
  await f.ctx.fiber.dispose();
});

test('late cleanup crosses under75K and rebuilds without a summary',async()=> {
  const f=fixture();appendVerboseError(f);
  const meter=f.ctx.tokenMeter.measure.bind(f.ctx.tokenMeter);
  const generation=f.agent.session.surface.replaceGeneration;
  f.ctx.tokenMeter.measure=(...args)=>({...meter(...args),totalTokens:f.agent.session.surface.replaceGeneration===generation ? 75001 : 74000});
  const action=await f.ctx.waterfall('agent/request-error',{agent:f.agent,failure:{code:'WATCHDOG_BOUNDARY'},signal},()=>undefined);
  assert.equal(action.kind,'retry');assert.equal(f.calls(),0);
  assert.equal(f.compact.record(f.agent).compactions,undefined);
  await f.ctx.fiber.dispose();
});

test('hygiene flush failure blocks subsequent requests even after surface changed',async()=> {
  const f=fixture();appendVerboseError(f);
  f.ctx.sessions.flush=async()=>{throw Error('disk unavailable');};
  await assert.rejects(f.compact.cleanToolOutputs(f.agent),/disk unavailable/);
  assert.equal(f.compact.record(f.agent).phase,'blocked');
  await assert.rejects(f.ctx.waterfall('agent/pre-step',{agent:f.agent,signal},()=>({kind:'enter'})),/reconciliation/);
  assert.equal(f.calls(),0);
  await f.ctx.fiber.dispose();
});

test('partial native pruning failure blocks retry admission',async()=> {
  const f=fixture();appendVerboseError(f);
  const pruner=f.ctx.get('toolResultPruner'), prune=pruner.pruneSession.bind(pruner);
  pruner.pruneSession=session=>{prune(session);throw Error('replacement failed after partial progress');};
  await assert.rejects(f.compact.cleanToolOutputs(f.agent),/partial progress/);
  assert.equal(f.compact.record(f.agent).phase,'blocked');
  await f.ctx.fiber.dispose();
});

test('Unicode pruning preserves surrogate pairs and explicit retrieval notice',async()=> {
  const f=fixture();
  const content=f.ctx.get('toolResultPruner').pruneContent([{type:'text',text:'🌱'.repeat(4000)}]);
  const text=content.map(b=>b.text).join('');
  assert.ok(!text.includes('\ufffd'));assert.ok(text.includes('hygiene-index.jsonl'));
  assert.ok(Array.from(text).length<=hygiene.thresholdChars);
  await f.ctx.fiber.dispose();
});

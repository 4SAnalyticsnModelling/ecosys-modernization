import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {pathToFileURL} from 'node:url';
import {policy,LIMIT,WINDOW,OUTPUT,HEADROOM,validateRoute,atomic,readState,notes,verifySummary,repeatCount} from '../core.mjs';
const repo = path.resolve(import.meta.dirname,'../../..');
const runtime = process.env.DSH_WATCHDOG_RUNTIME ?? path.join(os.homedir(),'.local/share/deepseek-harness/runtime');
process.env.DSH_WATCHDOG_RUNTIME = runtime;
async function installed(name) { return import(pathToFileURL(path.join(runtime,'node_modules/@deepseek-ai',name,'lib/index.js'))); }
const {Context} = await installed('cordis');
const {default:LlmRuntime,LlmAdapter,createUserMessage,createMessage} = await installed('dsh-llm');
const {default:SessionStore,SessionId} = await installed('dsh-session');
const {default:Projections} = await installed('dsh-session-projection');
const {default:TokenMeter} = await installed('dsh-token-meter');
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
  new LlmRuntime(ctx); new SessionStore(ctx); new Projections(ctx); new TokenMeter(ctx); new AgentRegistry(ctx);
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
  assert.ok(f.compact.record(f.agent).afterTokens < LIMIT);
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
  assert.equal(f.compact.record(f.agent).phase,'blocked');
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

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {LIMIT, WINDOW, policy, validateRoute, atomic, readState, notes, verifySummary, repeatCount, syncTree, snapshotWorktree} from './core.mjs';
const runtime = process.env.DSH_WATCHDOG_RUNTIME ?? path.resolve(import.meta.dirname,'../../runtime');
const defaultRoot = path.resolve(process.cwd(),'.dsh-watchdog');
function initializeWorkspace() {
  const root = process.env.DSH_WATCHDOG_ROOT ?? defaultRoot;
  process.env.DSH_WATCHDOG_ROOT = root;
  if (!fs.existsSync(path.join(root,'state.json'))) {
    if (fs.existsSync(path.join(root,'sessions')) && fs.readdirSync(path.join(root,'sessions')).length || fs.existsSync(path.join(root,'checkpoints')))
      throw Error('Missing watchdog state with prior sessions; refusing reset');
    fs.mkdirSync(path.join(root,'sessions'),{recursive:true});
    for (const file of ['progress.md','decisions.md','issues.md']) {
      if (!fs.existsSync(path.join(root,file))) fs.copyFileSync(path.join(import.meta.dirname,'templates',file),path.join(root,file));
    }
    atomic(path.join(root,'state.json'),{schema:1,sessions:{}});
  }
  readState(path.join(root,'state.json'));
  return root;
}
const {createUserMessage} = await import(pathToFileURL(path.join(runtime,'node_modules/@deepseek-ai/dsh-llm/lib/index.js')));
const {default:Basic} = await import(pathToFileURL(path.join(runtime,
  'node_modules/@deepseek-ai/dsh-compaction-basic/lib/index.js')));

// Native engine owns balanced selection, brackets, rollback, retention and commit.
// Only policy admission, checkpoints and fail-closed behavior are deployment-owned.
export default class WatchdogCompaction extends Basic {
  // Mount even without the meter, so the request gate can fail closed.
  static inject = ['llm','sessions','agents'];
  constructor(ctx) {
    const root = initializeWorkspace();
    super(ctx, {...policy, auto:true});
    ctx.inject(['systemPrompt'], promptCtx => {
      promptCtx.systemPrompt.section({name:'dsh-watchdog-global-rules',order:900,interpolate:false,
        text:fs.readFileSync(path.join(import.meta.dirname,'AGENTS.md'),'utf8') +
          '\nAuthoritative durable notes directory: '+root+'. Maintain progress.md, decisions.md and issues.md before major edits/tests; read them when resuming.'});
    });
  }
  root() {
    const root = process.env.DSH_WATCHDOG_ROOT;
    if (!root || !path.isAbsolute(root)) throw Error('Missing absolute watchdog root');
    return root;
  }
  update(agent, patch) {
    const file = path.join(this.root(), 'state.json');
    const state = readState(file);
    const old = state.sessions[agent.session.id] ?? {};
    state.sessions[agent.session.id] = {...old, ...patch, updatedAt:new Date().toISOString()};
    if (this.ctx.agents.roots().includes(agent)) state.currentSession = agent.session.id;
    atomic(file, state);
  }
  record(agent) { return readState(path.join(this.root(),'state.json')).sessions[agent.session.id] ?? {}; }
  measure(agent) {
    const m = this.ctx.tokenMeter?.measure(agent.session);
    if (!Number.isFinite(m?.totalTokens) || m.totalTokens < 0) throw Error('Missing/invalid token meter; refusing request');
    return m;
  }
  _registerAutomaticCompaction() {
    this.ctx.on('agent/created', ({agent, source}) => {
      const old = this.record(agent);
      if (source === 'resume' && process.env.DSH_WATCHDOG_AUTO_RESUME === '1' && old.phase === 'running' && old.taskActive === true) {
        notes(this.root());
        this.update(agent,{resumptions:(old.resumptions ?? 0)+1});
        agent.followup(createUserMessage({source:{kind:'user'},content:[{type:'text',text:
          'Resume the existing task from the durable session and watchdog notes. First reconcile current files, Git diff and recorded tests. Verify outcomes of interrupted tools before repeating actions. Preserve all scientific/code decisions; take the recorded next action.'}]}));
      }
    });
    this.ctx.on('agent/pre-step', async ({agent, signal}, next) => {
      notes(this.root());
      const state = this.record(agent);
      if (state.phase === 'checkpointing' || state.phase === 'compacting' || state.phase === 'blocked')
        throw Error(`Watchdog requires checkpoint reconciliation: ${state.checkpoint ?? agent.session.id}`);
      await this.compactIfNeeded(agent, 'pressure', signal);
      return next();
    });
    // Pre-step precedes admission of new user input. Gate again at the fully
    // assembled, logged request; ask the loop's supported error hook to rebuild.
    const owner = this;
    this.ctx.on('llm/stream', (options, next) => {
      if (options.purpose || options.provider !== 'mlx-local') return next();
      return {async *[Symbol.asyncIterator]() {
        const agent = owner.ctx.agents.get(options.sessionId);
        if (!agent) throw Error('No live session owner for routed request');
        const info = await owner.ctx.llm.resolveModelInfo(options.provider, options.model, options.signal);
        validateRoute(info.context?.contextWindow, options.maxTokens ?? info.defaultMaxTokens);
        const m = owner.measure(agent);
        const old = owner.record(agent);
        if (['checkpointing','compacting','blocked'].includes(old.phase)) throw Error('Watchdog recovery required');
        owner.update(agent, {phase:'running', provider:options.provider, model:options.model,
          taskActive:true, lastFinish:null, inputTokens:m.totalTokens, meterBaseline:m.baseline.kind, logRevision:m.logRevision,
          requestAt:new Date().toISOString()});
        if (m.totalTokens >= LIMIT) {
          yield {type:'finish',reason:{kind:'error',failure:{code:'WATCHDOG_BOUNDARY',message:'75K request boundary; rebuild after native compaction'}}};
          return;
        }
        const started = performance.now(); let first = true;
        for await (const chunk of next()) {
          if (first && /delta$/.test(chunk.type)) {
            first = false; owner.update(agent,{firstDeltaMs:performance.now()-started});
          }
          if (chunk.type === 'finish') owner.update(agent,{lastFinish:chunk.reason.kind,
            requestMs:performance.now()-started});
          yield chunk;
        }
      }};
    });
    this.ctx.on('agent/request-error', async ({agent, failure, signal}, next) => {
      if (signal.aborted) return next();
      if (failure.code === 'WATCHDOG_BOUNDARY') {
        const result = await this.compactIfNeeded(agent,'pressure',signal);
        if (!result) throw Error('Boundary cannot compact a balanced span; checkpoint retained');
        return {kind:'retry'};
      }
      if (failure.code === 'CONTEXT_WINDOW_EXCEEDED') {
        if ((this.record(agent).overflowRetries ?? 0) >= 1) throw Error('Repeated context overflow; manual diagnosis required');
        this.update(agent,{overflowRetries:1});
        const result = await this.compactIfNeeded(agent,'context-overflow',signal);
        if (result) return {kind:'retry'};
      }
      const old = this.record(agent), signature = `${failure.code}:${failure.message}`;
      const count = repeatCount(old.failure, signature);
      this.update(agent,{failure:{signature,count}, ...(count >= 3 ? {phase:'blocked'} : {})});
      return next();
    });
    this.ctx.on('session/event', (session, event) => {
      if (event.type === 'turn/start' || event.type === 'turn/end' && event.data.reason?.kind === 'completed') {
        const agent = this.ctx.agents.get(session.id);
        if (agent) this.update(agent,{taskActive:event.type === 'turn/start'});
        return;
      }
      if (event.type === 'assistant/message') {
        const agent = this.ctx.agents.get(session.id);
        if (agent) this.update(agent,{overflowRetries:0,failure:null});
        return;
      }
      if (event.type !== 'tool/call') return;
      // Exact repeated calls are only a diagnostic signal; pre-step blocks once
      // the same operation repeats eight times without a new signature.
      const agent = this.ctx.agents.get(session.id);
      if (!agent) return;
      const signature = crypto.createHash('sha256').update(JSON.stringify({name:event.data.name, arguments:event.data.arguments})).digest('hex');
      const count = repeatCount(this.record(agent).toolLoop, signature);
      this.update(agent,{toolLoop:{signature,count}, ...(count >= 8 ? {phase:'blocked'} : {})});
    });
  }
  async compactIfNeeded(agent, trigger, signal) {
    const before = this.measure(agent);
    if (trigger === 'pressure' && before.totalTokens < LIMIT) return null;
    const target = agent.session.requestHeader()?.config;
    if (!target) throw Error('Missing routed envelope at boundary');
    const info = await this.ctx.llm.resolveModelInfo(target.provider,target.model,signal);
    validateRoute(info.context?.contextWindow,target.maxTokens ?? info.defaultMaxTokens);
    const checkpoint = crypto.randomUUID(), dir = path.join(this.root(),'checkpoints',checkpoint);
    this.update(agent,{phase:'checkpointing',checkpoint,trigger,beforeTokens:before.totalTokens});
    try {
      fs.mkdirSync(dir,{recursive:true});
      if (!await this.ctx.sessions.flush(agent.session)) throw Error('No native persistence listener; refusing compaction');
      // Copy immutable session files only after awaited native persistence flush.
      fs.cpSync(path.join(this.root(),'sessions'),path.join(dir,'sessions'),{recursive:true});
      const memory = notes(this.root());
      fs.writeFileSync(path.join(dir,'notes.md'),memory.text,{mode:0o600});
      await snapshotWorktree(dir,process.cwd(),this.root());
      syncTree(dir);
      const parentFd = fs.openSync(path.dirname(dir),'r');
      try { fs.fsyncSync(parentFd); } finally { fs.closeSync(parentFd); }
      atomic(path.join(dir,'receipt.json'),{checkpoint,sessionId:agent.session.id,trigger,beforeTokens:before.totalTokens,meterBaseline:before.baseline.kind,notesHash:memory.hash});
      this.update(agent,{phase:'compacting'});
      const result = await super.compactIfNeeded(agent,trigger,signal);
      const after = this.measure(agent);
      if (!result || after.totalTokens >= LIMIT) throw Error('One compaction did not relieve pressure');
      if (!await this.ctx.sessions.flush(agent.session)) throw Error('Native persistence disappeared');
      atomic(path.join(dir,'completed.json'),{checkpoint,beforeTokens:before.totalTokens,afterTokens:after.totalTokens,trigger});
      this.update(agent,{phase:'running',afterTokens:after.totalTokens,compactions:(this.record(agent).compactions ?? 0)+1});
      return result;
    } catch (error) {
      this.update(agent,{phase:'blocked',error:String(error)});
      throw error;
    }
  }
  async summarize(input, agent, signal) {
    const memory = notes(this.root());
    const result = await super.summarize(input,agent,signal);
    if (notes(this.root()).hash !== memory.hash) throw Error('Notes changed during compaction');
    return verifySummary(result,memory,this.record(agent).checkpoint);
  }
}

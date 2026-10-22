import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {sessionRoot,snapshotSession} from './session-paths.mjs';
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
  // Preserve the native engine's dependencies: Cordis enforces injection when
  // sibling plugins provide services, unlike direct construction in a root context.
  static inject = [...Basic.inject,'agents','sessionPersistence'];
  constructor(ctx) {
    const root = initializeWorkspace();
    super(ctx, {...policy, auto:true});
    ctx.inject(['systemPrompt'], promptCtx => {
      promptCtx.systemPrompt.section({name:'dsh-watchdog-global-rules',order:900,interpolate:false,
        text:context=> {
          const agent=context.scope;
          if(!agent?.session)return '';
          return fs.readFileSync(path.join(import.meta.dirname,'AGENTS.md'),'utf8') +
            '\nAuthoritative durable notes directory: '+this.root(agent)+'. Maintain progress.md, decisions.md and issues.md before major edits/tests; read them when resuming.';
        }});
    });
  }
  root(agent) {
    const root = process.env.DSH_WATCHDOG_ROOT;
    if (!root || !path.isAbsolute(root)) throw Error('Missing absolute watchdog root');
    return sessionRoot(root,agent.session.id);
  }
  update(agent, patch) {
    const file = path.join(this.root(agent), 'state.json');
    const state = readState(file);
    const old = state.sessions[agent.session.id] ?? {};
    state.sessions[agent.session.id] = {...old, ...patch, updatedAt:new Date().toISOString()};
    const isRoot=this.ctx.agents.roots().includes(agent);
    if(isRoot)state.currentSession=agent.session.id;
    atomic(file,state);
    if(isRoot) {
      const base=process.env.DSH_WATCHDOG_ROOT;
      if(base!==this.root(agent)){const index=readState(path.join(base,'state.json'));index.currentSession=agent.session.id;atomic(path.join(base,'state.json'),index);}
    }
  }
  record(agent) { return readState(path.join(this.root(agent),'state.json')).sessions[agent.session.id] ?? {}; }
  reconcileSummaryFailure(agent) {
    const state = this.record(agent);
    const message = 'summarization truncated at the token cap (incomplete checkpoint)';
    if (state.phase !== 'blocked' || state.error !== 'Error: '+message) return false;
    const events = agent.session.snapshotEvents();
    const start = events.findLast(e => e.type === 'compaction/start');
    const end = events.findLast(e => e.type === 'compaction/end');
    // Adjacent brackets prove the native engine never appended a replacement.
    if (!start || !end || end.seq !== start.seq+1 ||
        end.data.compactionId !== start.data.compactionId || end.data.error !== message) return false;
    const dir = path.join(this.root(agent),'checkpoints',state.checkpoint);
    const receipt = JSON.parse(fs.readFileSync(path.join(dir,'receipt.json'),'utf8'));
    if (receipt.sessionId !== agent.session.id || receipt.checkpoint !== state.checkpoint ||
        fs.existsSync(path.join(dir,'completed.json')) || !fs.existsSync(path.join(dir,'sessions'))) return false;
    atomic(path.join(dir,'reconciliation.json'),{checkpoint:state.checkpoint,
      reason:'Native summary failed before commit; original surface retained',
      startSeq:start.seq,endSeq:end.seq,at:new Date().toISOString()});
    this.update(agent,{phase:'running',error:null,recoveryPending:true,reconciledCheckpoint:state.checkpoint});
    return true;
  }
  measure(agent) {
    const m = this.ctx.tokenMeter?.measure(agent.session);
    if (!Number.isFinite(m?.totalTokens) || m.totalTokens < 0) throw Error('Missing/invalid token meter; refusing request');
    return m;
  }
  async cleanToolOutputs(agent) {
    const pruner = this.ctx.get('toolResultPruner');
    if (!pruner) throw Error('Continuous context hygiene service is missing; refusing request');
    this.measure(agent); // Missing metering fails before any rewrite.
    try {
      const result = pruner.pruneSession(agent.session);
      if (result.pruned.length) {
        if (!await this.ctx.sessions.flush(agent.session)) throw Error('No persistence listener for context hygiene');
        const index=path.join(this.root(agent),'hygiene-index.jsonl');
        const fd=fs.openSync(index,'a',0o600);
        try {
          for(const item of result.pruned) fs.writeSync(fd,JSON.stringify({sessionId:agent.session.id,
            sessionsRoot:path.join(process.env.DSH_WATCHDOG_ROOT,'sessions'),...item})+'\n');
          fs.fsyncSync(fd);
        } finally { fs.closeSync(fd); }
        const old = this.record(agent);
        this.update(agent,{hygienePrunes:(old.hygienePrunes ?? 0)+result.pruned.length,
          hygieneCharsRemoved:(old.hygieneCharsRemoved ?? 0)+result.charsRemoved,
          hygieneAt:new Date().toISOString()});
      }
      return result;
    } catch (error) {
      this.update(agent,{phase:'blocked',error:'Context hygiene failed: '+String(error)});
      throw error;
    }
  }
  _registerAutomaticCompaction() {
    this.ctx.on('agent/created', ({agent, source}) => {
      this.reconcileSummaryFailure(agent);
      const old = this.record(agent);
      if (source === 'resume' && process.env.DSH_WATCHDOG_AUTO_RESUME === '1' && old.phase === 'running' && old.taskActive === true) {
        notes(this.root(agent));
        this.update(agent,{resumptions:(old.resumptions ?? 0)+1});
        agent.followup(createUserMessage({source:{kind:'user'},content:[{type:'text',text:
          'Resume the existing task from the durable session and watchdog notes. First reconcile current files, Git diff and recorded tests. Verify outcomes of interrupted tools before repeating actions. Preserve all scientific/code decisions; take the recorded next action.'}]}));
      }
    });
    this.ctx.on('agent/pre-step', async ({agent, signal}, next) => {
      notes(this.root(agent));
      this.reconcileSummaryFailure(agent);
      const state = this.record(agent);
      if (state.phase === 'checkpointing' || state.phase === 'compacting' || state.phase === 'blocked')
        throw Error(`Watchdog requires checkpoint reconciliation: ${state.checkpoint ?? agent.session.id}`);
      await this.cleanToolOutputs(agent);
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
        if(readState(path.join(process.env.DSH_WATCHDOG_ROOT,'state.json')).layout==='per-agent-v1' &&
           old.provider && (old.provider!==options.provider || old.model!==options.model))
          throw Error('Model isolation requires a fresh native conversation; previous session remains preserved');
        if (['checkpointing','compacting','blocked'].includes(old.phase)) throw Error('Watchdog recovery required');
        owner.update(agent, {phase:'running', provider:options.provider, model:options.model,
          taskActive:true, lastFinish:null, logRevision:m.logRevision,
          requestAt:new Date().toISOString()});
        if (m.totalTokens >= LIMIT) {
          yield {type:'finish',reason:{kind:'error',failure:{code:'WATCHDOG_BOUNDARY',message:'75K request boundary; rebuild after native compaction'}}};
          return;
        }
        const started = performance.now(); let first = true;
        for await (const chunk of next()) {
          if (first && /delta$/.test(chunk.type)) {
            first = false;
          }
          if (chunk.type === 'finish') owner.update(agent,{lastFinish:chunk.reason.kind});
          yield chunk;
        }
      }};
    });
    this.ctx.on('agent/request-error', async ({agent, failure, signal}, next) => {
      if (signal.aborted) return next();
      if (failure.code === 'WATCHDOG_BOUNDARY') {
        const generation = agent.session.surface.replaceGeneration;
        await this.cleanToolOutputs(agent);
        const result = await this.compactIfNeeded(agent,'pressure',signal);
        if (!result && agent.session.surface.replaceGeneration <= generation) throw Error('Boundary cannot compact a balanced span; checkpoint retained');
        return {kind:'retry'};
      }
      if (failure.code === 'CONTEXT_WINDOW_EXCEEDED') {
        if ((this.record(agent).overflowRetries ?? 0) >= 1) throw Error('Repeated context overflow; preserve checkpoint and recover in a fresh context');
        this.update(agent,{overflowRetries:1});
        const result = await this.compactIfNeeded(agent,'context-overflow',signal);
        if (result) return {kind:'retry'};
      }
      const old = this.record(agent), signature = `${failure.code}:${failure.message}`;
      const count = repeatCount(old.failure, signature);
      this.update(agent,{failure:{signature,count}});
      if (count === 3) agent.followup(createUserMessage({source:{kind:'user'},content:[{type:'text',text:'Repeated failure: reconcile durable evidence, reduce the reproducer or change approach. Continue the objective; do not retry the same failed operation blindly.'}]}));
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
      this.update(agent,{toolLoop:{signature,count}});
      if (count === 8) agent.followup(createUserMessage({source:{kind:'user'},content:[{type:'text',text:'Repeated tool operation: inspect the existing result and live process identity. For a healthy long job keep observing; otherwise choose a smaller decisive experiment. Continue without duplicating side effects.'}]}));
    });
  }
  async compactIfNeeded(agent, trigger, signal) {
    const before = this.measure(agent);
    if (trigger === 'pressure' && before.totalTokens < LIMIT) return null;
    const target = agent.session.requestHeader()?.config;
    if (!target) throw Error('Missing routed envelope at boundary');
    const info = await this.ctx.llm.resolveModelInfo(target.provider,target.model,signal);
    validateRoute(info.context?.contextWindow,target.maxTokens ?? info.defaultMaxTokens);
    const checkpoint = crypto.randomUUID(), dir = path.join(this.root(agent),'checkpoints',checkpoint);
    this.update(agent,{phase:'checkpointing',checkpoint,trigger});
    try {
      fs.mkdirSync(dir,{recursive:true});
      if (!await this.ctx.sessions.flush(agent.session)) throw Error('No native persistence listener; refusing compaction');
      // Copy immutable session files only after awaited native persistence flush.
      await snapshotSession(process.env.DSH_WATCHDOG_ROOT,agent.session.id,path.join(dir,'sessions'),this.ctx.sessionPersistence);
      const memory = notes(this.root(agent));
      fs.writeFileSync(path.join(dir,'notes.md'),memory.text,{mode:0o600});
      await snapshotWorktree(dir,process.cwd(),process.env.DSH_WATCHDOG_ROOT);
      syncTree(dir);
      const parentFd = fs.openSync(path.dirname(dir),'r');
      try { fs.fsyncSync(parentFd); } finally { fs.closeSync(parentFd); }
      atomic(path.join(dir,'receipt.json'),{checkpoint,sessionId:agent.session.id,trigger,notesHash:memory.hash});
      this.update(agent,{phase:'compacting'});
      const result = await super.compactIfNeeded(agent,trigger,signal);
      const after = this.measure(agent);
      if (!result || after.totalTokens >= LIMIT) throw Error('One compaction did not relieve pressure');
      if (!await this.ctx.sessions.flush(agent.session)) throw Error('Native persistence disappeared');
      atomic(path.join(dir,'completed.json'),{checkpoint,trigger,capacitySafe:true});
      this.update(agent,{phase:'running',capacitySafe:true,compactions:(this.record(agent).compactions ?? 0)+1});
      return result;
    } catch (error) {
      this.update(agent,{phase:'blocked',error:String(error)});
      throw error;
    }
  }
  async summarize(input, agent, signal) {
    const memory = notes(this.root(agent));
    let result;
    const fallback = () => {
      const reason=this.record(agent).recoveryReason ?? 'MAX_TOKENS';
      if (!['MAX_TOKENS','INTERRUPTED_BEFORE_PUBLICATION'].includes(reason))
        throw Error('Unknown summary recovery reason; preserve checkpoint');
      const checkpoint = this.record(agent).checkpoint;
      const archive = path.join(this.root(agent),'checkpoints',checkpoint);
      // This is a complete deterministic recovery record, never truncated model output.
      // Keep the selected prefix verbatim for targeted retrieval; native retains its tail.
      const file = path.join(archive,'summary-input.json');
      atomic(file,input);
      const requests = input.messages.filter(m => m.role === 'user' && m.source?.kind === 'user')
        .map(m => m.content.filter(b => b.type === 'text').map(b => b.text).join('\n'));
      const text = (reason==='INTERRUPTED_BEFORE_PUBLICATION'
        ? 'Recovery checkpoint: the prior owner exited before publishing a summary; the unchanged original surface was verified against its saved checkpoint. '
        : 'Recovery checkpoint: the model summary was unavailable at its output cap. ')+
        'No partial model summary is used. Verified durable notes are attached below; '+
        'the recent conversation remains after this checkpoint. Full selected conversation, '+
        'including every original request, decision, tool call and result, is preserved at '+file+'. '+
        'Original native session, Git changes and notes are preserved in '+archive+'. '+
        'Before continuing, read the durable notes and retrieve relevant ranges from that archive '+
        'to resolve any missing context. Never infer that pending work or a test succeeded.\n'+
        (requests.length ? 'Original user request (excerpt; full text in archive):\n'+requests[0].slice(0,6000)+
          '\nLatest user request (excerpt; full text in archive):\n'+requests.at(-1).slice(0,6000) : '');
      atomic(path.join(archive,'summary-fallback.json'),{reason,inputFile:file,at:new Date().toISOString()});
      this.update(agent,{recoveryPending:false,recoveryReason:null,summaryFallbacks:(this.record(agent).summaryFallbacks ?? 0)+1});
      return {summary:[{type:'text',text}],provider:this.record(agent).provider ?? agent.options.provider,
        model:this.record(agent).model ?? agent.options.model,maxTokens:policy.maxTokens};
    };
    if (this.record(agent).recoveryPending) result = fallback();
    else {
      try { result = await super.summarize(input,agent,signal); }
      catch (error) {
        if (error.code !== 'MAX_TOKENS' || signal?.aborted) throw error;
        result = fallback();
      }
    }
    if (notes(this.root(agent)).hash !== memory.hash) throw Error('Notes changed during compaction');
    return verifySummary(result,memory,this.record(agent).checkpoint);
  }
}

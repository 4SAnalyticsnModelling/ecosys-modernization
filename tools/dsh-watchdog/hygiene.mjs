// Native replay-safe pruning plus an explicit full-output retrieval pointer.
import path from 'node:path';
import {AsyncLocalStorage} from 'node:async_hooks';
import {sessionRoot} from './session-paths.mjs';
import {pathToFileURL} from 'node:url';
const runtime=process.env.DSH_WATCHDOG_RUNTIME ?? path.resolve(import.meta.dirname,'../../runtime');
const {default:NativePruner}=await import(pathToFileURL(path.join(runtime,
  'node_modules/@deepseek-ai/dsh-compaction-tool-result-pruner/lib/index.js')));
export default class ArtifactPruner extends NativePruner {
  roots=new AsyncLocalStorage();
  pruneSession(session) {
    const base=process.env.DSH_WATCHDOG_ROOT ?? path.resolve(process.cwd(),'.dsh-watchdog');
    return this.roots.run(sessionRoot(base,session.id),()=>super.pruneSession(session));
  }
  pruneContent(blocks) {
    const content=super.pruneContent(blocks);
    if (!content)return null;
    const root=this.roots.getStore() ?? process.env.DSH_WATCHDOG_ROOT ?? path.resolve(process.cwd(),'.dsh-watchdog');
    const text='\nFull original retained in session storage; find its session ID, tool call ID and original sequence in '+path.join(root,'hygiene-index.jsonl')+'.';
    if(this.measureContent(content)+Array.from(text).length>this.config.thresholdChars)
      throw Error('Output retrieval pointer exceeds hygiene budget');
    return [...content,{type:'text',text}];
  }
}

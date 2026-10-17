import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {policy,WINDOW,OUTPUT,hygiene,INLINE_TOKENS} from './core.mjs';
const installation = process.env.DSH_INSTALLED_ROOT ?? path.resolve(import.meta.dirname,'../..');
const {default:YAML} = await import(pathToFileURL(path.join(installation,'runtime/node_modules/yaml/dist/index.js')));
export function configureContext(doc) {
  // Preserve all native expressions/preset definitions, replace only context policy.
  doc.contents.items = doc.contents.items.filter(row => {
    const insert = row?.get?.('insert');
    return !(YAML.isSeq(insert) && insert.items.length === 1 &&
      ['local-bounded-compaction','global-watchdog-compaction','global-watchdog-hygiene','global-code-presentation','global-code-runtime'].includes(insert.items[0]?.get?.('id')));
  });
  YAML.visit(doc,{Map(_key,node) {
    const id=node.get('id');
    if (id==='tools') node.setIn(['config','mode'],'both');
    if (id==='ptc-runtime') {
      node.set('name','@deepseek-ai/dsh-ptc-runtime-node');
      node.set('disabled',true);
    }
    if (id==='tool-presentation') node.setIn(['config','mode'],'both');
    if (['compaction-basic','command-compact','tool-result-pruner','image-offload'].includes(id)) node.set('disabled',true);
    if (id==='compaction' && node.get('isolate')) {
      node.get('isolate').delete('compaction');node.get('isolate').delete('toolResultPruner');
    }
    if (id==='spill-policy') node.set('config',doc.createNode({maxInlineTokens:INLINE_TOKENS}));
    if (id==='llm-pi-ai') {
      let provider=node.getIn(['config','providers','mlx-local']);
      if (!provider) return;
      if (!YAML.isMap(provider)) {
        node.setIn(['config','providers','mlx-local'],doc.createNode(provider));
        provider=node.getIn(['config','providers','mlx-local']);
      }
      provider.set('defaultContextWindow',WINDOW);provider.set('defaultMaxTokens',OUTPUT);
      for(const model of provider.get('models')?.items ?? []) {
        if (model.get('contextWindow') < WINDOW) throw Error('Local model lacks required 131072-token route: '+model.get('id'));
        model.set('contextWindow',WINDOW);model.set('maxTokens',Math.min(model.get('maxTokens') ?? OUTPUT,OUTPUT));
      }
    }
  }});
  for (const entry of [
    {id:'compaction-basic',disabled:true},
    {id:'command-compact',disabled:true},
    {id:'tool-result-pruner',disabled:true},
    {id:'image-offload',disabled:true},
    {id:'spill-policy',config:{maxInlineTokens:INLINE_TOKENS}},
  ]) {
    let existing=doc.contents.items.find(row=>row?.get?.('id')===entry.id);
    if (existing) {
      if (entry.id==='tool-result-pruner') existing.delete('name');
      if (entry.disabled !== undefined) existing.set('disabled',entry.disabled);
      if (entry.config) existing.set('config',doc.createNode(entry.config));
    } else doc.add(doc.createNode(entry));
  }
  const persistence = YAML.parseDocument(`- id: session-persistence-jsonl\n  config:\n    root: !!js process.env.DSH_WATCHDOG_ROOT + '/sessions'\n`);
  doc.contents.items=doc.contents.items.filter(row=>row?.get?.('id')!=='session-persistence-jsonl');
  doc.add(persistence.contents.items[0].clone());
  doc.add(doc.createNode({insert:[{id:'global-watchdog-hygiene',name:path.join(installation,'tool-env/watchdog/hygiene.mjs'),config:hygiene}]}));
  doc.add(doc.createNode({insert:[{id:'global-watchdog-compaction',name:path.join(installation,'tool-env/watchdog/plugin.mjs'),config:policy}]}));
  if (!doc.contents.items.some(row=>row?.get?.('id')==='ptc-runtime'))
    doc.add(doc.createNode({id:'ptc-runtime',disabled:true}));
  doc.add(doc.createNode({insert:[{id:'global-code-runtime',name:path.join(installation,'tool-env/watchdog/code-mode.mjs')}]}));
  let tools=doc.contents.items.find(row=>row?.get?.('id')==='tools');
  if (!tools) doc.add(doc.createNode({id:'tools',config:{mode:'both'}}));
}

export function syncProfiles(local, defaultModel) {
  const home = process.env.DSH_HOME ?? path.join(process.env.USERPROFILE ?? process.getBuiltinModule('node:os').homedir(),'.dsh');
  const root = path.join(home,'profiles');
  for (const name of fs.readdirSync(root)) {
    if (name==='dsh-tui') continue;
    const file=path.join(root,name,'cordis.patch.yml');
    if (!fs.existsSync(file)) continue;
    const doc=YAML.parseDocument(fs.readFileSync(file,'utf8'));
    if (doc.errors.length) throw doc.errors[0];
    for (const [id, config] of [
      ['llm-pi-ai',{providers:{'mlx-local':local}}],
      ['agent-default-model',defaultModel],
    ]) {
      const entry=doc.contents.items.find(row=>row?.get?.('id')===id);
      if (entry) entry.set('config',doc.createNode(config));
      else doc.add(doc.createNode({id,config}));
    }
    configureContext(doc);
    const tmp=file+'.watchdog-tmp';fs.writeFileSync(tmp,doc.toString(),{mode:0o600});fs.renameSync(tmp,file);
  }
}

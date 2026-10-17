import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {atomic,policy,WINDOW,OUTPUT,hygiene,INLINE_TOKENS} from './core.mjs';
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const root = path.join(repo,'watchdog');
const installed = process.env.DSH_INSTALLED_ROOT ?? path.join(os.homedir(),'.local/share/deepseek-harness');
const original = process.env.DSH_INSTALLED_PROFILE ?? path.join(os.homedir(),'.dsh/profiles/dsh-tui');
const runtime = path.join(installed,'runtime');
const {default:YAML} = await import(pathToFileURL(path.join(runtime,'node_modules/yaml/dist/index.js')));
const version = JSON.parse(fs.readFileSync(path.join(runtime,'node_modules/@deepseek-ai/dsh/package.json'))).version;
if (version !== '0.2.0-rc.2') throw Error(`Unverified installed dsh version ${version}; revalidate contracts before upgrading`);
const doc = YAML.parseDocument(fs.readFileSync(path.join(original,'cordis.patch.yml'),'utf8'));
if (doc.errors.length) throw doc.errors[0];
const profiles = JSON.parse(fs.readFileSync(path.join(installed,'local-mlx/profiles.json')));
const catalog = [];
YAML.visit(doc,{Map(_key,node) {
  const id = node.get('id'), name = node.get('name');
  if (id === 'llm-pi-ai') {
    const provider = node.getIn(['config','providers','mlx-local']);
    const models = provider.get('models');
    for (const model of models.items) {
      const modelId = model.get('id');
      const p = Object.entries(profiles).find(([file])=>file.endsWith('/'+modelId))?.[1];
      if (!p || p.max_context_window < WINDOW) throw Error(`Route ${modelId} cannot satisfy 131072; refusing setup`);
      catalog.push({id:modelId,configuredBackendWindow:p.max_context_window,effectiveWindow:WINDOW,outputTokens:OUTPUT,
        liveCapacityVerified:false});
      model.set('contextWindow',WINDOW); model.set('maxTokens',OUTPUT);
    }
    provider.set('defaultContextWindow',WINDOW); provider.set('defaultMaxTokens',OUTPUT);
  }
  if (id === 'local-bounded-compaction' || id === 'global-watchdog-compaction') {
    node.set('name',path.join(repo,'tools/dsh-watchdog/plugin.mjs'));
    node.set('config',doc.createNode(policy)); node.set('disabled',false);
  }
  if (id === 'global-watchdog-hygiene') {node.set('name',path.join(repo,'tools/dsh-watchdog/hygiene.mjs'));node.set('config',doc.createNode(hygiene));}
  if (id === 'compaction-basic') node.set('disabled',true);
  if (id === 'compaction' && node.get('isolate')) {
    node.get('isolate').delete('compaction');
    node.get('isolate').delete('toolResultPruner');
  }
  if (['command-compact','tool-result-pruner','image-offload','local-task-tool-environment'].includes(id)) node.set('disabled',true);
  if (id === 'spill-policy') node.set('config',doc.createNode({maxInlineTokens:INLINE_TOKENS}));
  if (id === 'session-persistence-jsonl') node.set('config',doc.createNode({root:path.join(root,'sessions')}));
}});
for (const row of doc.contents.items) if (row?.get?.('id')==='tool-result-pruner') row.delete('name');
for (const override of [
  {id:'spill-policy', config:{maxInlineTokens:INLINE_TOKENS}},
  {id:'image-offload', disabled:true},
  {id:'tool-result-pruner', disabled:true},
  {id:'session-persistence-jsonl', config:{root:path.join(root,'sessions')}},
]) doc.add(doc.createNode(override));
const profile = path.join(root,'home/profiles/dsh-tui');
fs.mkdirSync(profile,{recursive:true});
for (const file of ['package.json','cordis.yml']) fs.copyFileSync(path.join(original,file),path.join(profile,file));
// Reuse installed packages read-only; all generated profile/state stays here.
const modules = path.join(profile,'node_modules');
if (fs.existsSync(modules) && fs.lstatSync(modules).isSymbolicLink()) fs.unlinkSync(modules);
fs.mkdirSync(modules,{recursive:true});
for (const entry of fs.readdirSync(path.join(original,'node_modules'))) {
  if (entry === '@deepseek-harness-tui') continue;
  const dest = path.join(modules,entry);
  if (!fs.existsSync(dest)) fs.symlinkSync(path.join(original,'node_modules',entry),dest,'dir');
}
// Installed TUI hardcodes ~/.dsh-tui. A private copy changes only that storage
// path; the harness core and all context services remain installed/unmodified.
const tuiSource = path.join(original,'node_modules/@deepseek-harness-tui/dsh-tui');
const tuiLocal = path.join(root,'tui');
if (!fs.existsSync(tuiLocal)) {
  fs.cpSync(tuiSource,tuiLocal,{recursive:true,filter:src=>path.basename(src)!=='node_modules'});
  fs.symlinkSync(path.join(tuiSource,'node_modules'),path.join(tuiLocal,'node_modules'),'dir');
}
const pathsFile = path.join(tuiLocal,'lib/types/utils/paths.js');
let pathsSource = fs.readFileSync(pathsFile,'utf8');
pathsSource = pathsSource.replace("export const DATA_DIR = join(homeDir(), '.dsh-tui');",
  "export const DATA_DIR = process.env.DSH_WATCHDOG_TUI_DATA ?? join(homeDir(), '.dsh-tui');");
fs.writeFileSync(pathsFile,pathsSource);
const scope = path.join(modules,'@deepseek-harness-tui');
fs.mkdirSync(scope,{recursive:true});
if (!fs.existsSync(path.join(scope,'dsh-tui'))) fs.symlinkSync(tuiLocal,path.join(scope,'dsh-tui'),'dir');
fs.writeFileSync(path.join(profile,'cordis.patch.yml'),doc.toString(),{mode:0o600});
for (const f of ['progress.md','decisions.md','issues.md']) {
  if (!fs.existsSync(path.join(root,f))) fs.copyFileSync(path.join(repo,'tools/dsh-watchdog/templates',f),path.join(root,f));
}
fs.mkdirSync(path.join(root,'sessions'),{recursive:true});
if (!fs.existsSync(path.join(root,'state.json'))) {
  if (fs.readdirSync(path.join(root,'sessions')).length || fs.existsSync(path.join(root,'checkpoints')))
    throw Error('Watchdog state missing with existing sessions/checkpoints; refusing reset');
  atomic(path.join(root,'state.json'),{schema:1,sessions:{}});
}
atomic(path.join(root,'installation.json'),{version,runtime,originalProfile:original,repo,models:catalog,createdAt:new Date().toISOString()});
console.log(JSON.stringify({version,models:catalog,profile},null,2));

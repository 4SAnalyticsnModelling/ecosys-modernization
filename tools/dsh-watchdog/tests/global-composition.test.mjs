import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import os from 'node:os';
import {execFileSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const installed=path.join(os.homedir(),'.local/share/deepseek-harness');
const {default:YAML}=await import(pathToFileURL(path.join(installed,'runtime/node_modules/yaml/dist/index.js')));
for(const profile of ['dsh-tui','dsh-tui-safe','headless']) test('global '+profile+' has one policy and four 131K routes',()=> {
  const text=execFileSync('node',[path.join(installed,'runtime/node_modules/@deepseek-ai/dsh/lib/bin.js'),
    '--profile',profile,'--dump-config'],{encoding:'utf8',env:{...process.env,DSH_WATCHDOG_ROOT:path.resolve('.tmp/config-test')}});
  const doc=YAML.parseDocument(text,{logLevel:'silent'});
  let active=0,models=0,pruners=0,spills=0,codeRuntimes=0,toolRegistries=0;
  YAML.visit(doc,{Map(_key,node) {
    const name=node.get('name'),id=node.get('id');
    if (id==='ptc-runtime') assert.equal(node.get('disabled'),true);
    if (id==='global-code-runtime') {codeRuntimes++;assert.ok(name.endsWith('/code-mode.mjs'));}
    if (id==='tool-presentation') assert.equal(node.getIn(['config','mode']),'both');
    if (id==='tools') {toolRegistries++;assert.equal(node.getIn(['config','mode']),'both');}
    if(typeof name==='string' && /(?:compaction-basic|bounded-compaction|watchdog\/plugin\.mjs)/.test(name) && node.get('disabled')!==true) {
      active++;assert.equal(id,'global-watchdog-compaction');
      assert.equal(node.getIn(['config','thresholdRatio']),75000/131072);
    }
    if((id==='tool-result-pruner' || id==='global-watchdog-hygiene') && node.get('disabled')!==true) {
      pruners++;assert.ok(name.includes('watchdog/hygiene.mjs'));
      assert.equal(node.getIn(['config','thresholdChars']),2048);
      assert.equal(node.getIn(['config','headChars']),768);
      assert.equal(node.getIn(['config','tailChars']),384);
    }
    if(id==='spill-policy') {spills++;assert.equal(node.getIn(['config','maxInlineTokens']),1200);}
    if(node.has('contextWindow')) {models++;assert.equal(node.get('contextWindow'),131072);}
    if(id==='compaction') assert.notEqual(node.getIn(['isolate','compaction']),true);
  }});
  assert.equal(active,1);assert.equal(models,4);assert.equal(pruners,1);assert.equal(spills,1);
  assert.equal(codeRuntimes,1);assert.equal(toolRegistries,1);
});

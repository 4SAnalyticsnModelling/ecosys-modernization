import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import {pathToFileURL} from 'node:url';

const runtime=process.env.DSH_WATCHDOG_RUNTIME ?? path.join(os.homedir(),'.local/share/deepseek-harness/runtime');
process.env.DSH_WATCHDOG_RUNTIME=runtime;
const load=name=>import(pathToFileURL(path.join(runtime,'node_modules/@deepseek-ai',name,'lib/index.js')));
const {Context}=await load('cordis');
const {default:Subprocess}=await load('dsh-subprocess-local');
const {default:Tools,defineTool}=await load('dsh-tools');
const {default:Runtime}=await import('../code-mode.mjs');

test('native code mode exposes both tools and batches calls beyond old deadlines',async t=>{
  const prior=process.env.DSH_WATCHDOG_ROOT;
  process.env.DSH_WATCHDOG_ROOT=fs.mkdtempSync(path.join(process.cwd(),'.tmp/code-mode-'));
  const ctx=new Context();
  t.after(async()=>{await ctx.fiber.dispose();if(prior===undefined)delete process.env.DSH_WATCHDOG_ROOT;else process.env.DSH_WATCHDOG_ROOT=prior;});
  new Subprocess(ctx);
  ctx.provide('sandboxPolicy',{defaultMode:'danger-full-access'});
  ctx.provide('fs',{processPathFromHostPath:p=>p});
  ctx.provide('systemPrompt',{tools(){},section(){},getSectionOrder(){return 10;}});
  const provider=new Runtime(ctx,{timeoutMs:10,maxTimeoutMs:100,maxOutputBytes:1048576,
    maxOldGenerationSizeMb:128,maxMessageBytes:1048576,maxPendingCalls:8,graceMs:1000});
  const tools=new Tools(ctx,{mode:'both'});
  tools.register(defineTool({name:'double',description:'Double a number',
    parameters:{n:{type:'number',required:true}},output:{schema:{type:'number'}},execute:async ({n})=>n*2}));
  const names=tools.wireSchemas().schemas.map(tool=>tool.name);
  assert.ok(names.includes('run_code'));
  assert.ok(names.includes('double'));
  const spec=provider.resolve({program:'return await Promise.all([tools.double({n:2}),tools.double({n:3})]);',
    bindings:[{global:'tools',functions:{double:async ({n})=>{
      await new Promise(r=>setTimeout(r,50));return n*2;
    }}}],cwd:process.cwd(),timeoutMs:1,
    sandboxPolicy:{mode:'danger-full-access',workspaceRoot:process.cwd()}});
  assert.equal(spec.timeoutMs,null);
  const result=await provider.run(spec);
  assert.equal(result.error,undefined);
  assert.deepEqual(result.value,[4,6]);
});

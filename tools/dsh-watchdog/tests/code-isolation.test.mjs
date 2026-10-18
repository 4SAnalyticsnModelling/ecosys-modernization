import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {pathToFileURL} from 'node:url';
import {apply as isolate} from '../execution-isolation.mjs';
const repo=path.resolve(import.meta.dirname,'../../..');
const runtime=process.env.DSH_WATCHDOG_RUNTIME??path.join(os.homedir(),'.local/share/deepseek-harness/runtime');
process.env.DSH_WATCHDOG_RUNTIME=runtime;
const installed=name=>import(pathToFileURL(path.join(runtime,'node_modules/@deepseek-ai',name,'lib/index.js')));
const {Context}=await installed('cordis');
const {default:Subprocess}=await installed('dsh-subprocess-local');
const {default:Runtime}=await import('../code-mode.mjs');
test('two actual native code runtimes keep temp files private and strip inherited credentials',async()=>{
 const base=fs.mkdtempSync(path.join(repo,'.tmp/native-code-isolation-'));
 const previous=process.env.DSH_WATCHDOG_ROOT;process.env.DSH_WATCHDOG_ROOT=base;
 const secret=process.env.ISOLATION_TEST_SECRET;process.env.ISOLATION_TEST_SECRET='must-not-reach-code';
 fs.writeFileSync(path.join(base,'state.json'),JSON.stringify({schema:1,sessions:{},layout:'per-agent-v1'}));
 const ctx=new Context();new Subprocess(ctx);ctx.provide('sandboxPolicy',{defaultMode:'danger-full-access'});ctx.provide('fs',{processPathFromHostPath:p=>p});
 let hook;
 isolate({shell:{resolve:x=>x},shellEnv:{register(){}},on:(_name,fn)=>{hook=fn;},inject:(_deps,fn)=>fn(ctx)});
 const code=new Runtime(ctx,{timeoutMs:10,maxTimeoutMs:100,maxOutputBytes:1048576,maxOldGenerationSizeMb:128,maxMessageBytes:1048576,maxPendingCalls:8,graceMs:1000});
 const run=id=>hook({agent:{session:{id}}},async()=>{
  const program=`const os=await import('node:os');const fs=await import('node:fs/promises');const path=await import('node:path');const temp=os.tmpdir();if(!temp.startsWith(${JSON.stringify(base)}+'/agents/'))throw Error('Temporary path escaped owner');const directory=await fs.mkdtemp(path.join(temp,'proof-'));await fs.writeFile(path.join(directory,'owner'),${JSON.stringify(id)});return {temp,directory,secret:process.env.ISOLATION_TEST_SECRET??null};`;
  const spec=code.resolve({program,bindings:[],cwd:repo,timeoutMs:1,sandboxPolicy:{mode:'danger-full-access',workspaceRoot:repo}});
  assert.equal(spec.timeoutMs,null);
  const result=await code.run(spec);assert.equal(result.error,undefined,JSON.stringify(result));return result.value;
 });
 try{
  const [a,b]=await Promise.all([run('same-model-a'),run('same-model-b')]);
  assert.notEqual(a.temp,b.temp);assert.equal(a.secret,null);assert.equal(b.secret,null);
  assert.equal(fs.readFileSync(path.join(a.directory,'owner'),'utf8'),'same-model-a');
  assert.equal(fs.readFileSync(path.join(b.directory,'owner'),'utf8'),'same-model-b');
 }finally{
  await ctx.fiber.dispose();
  if(previous===undefined)delete process.env.DSH_WATCHDOG_ROOT;else process.env.DSH_WATCHDOG_ROOT=previous;
  if(secret===undefined)delete process.env.ISOLATION_TEST_SECRET;else process.env.ISOLATION_TEST_SECRET=secret;
 }
});

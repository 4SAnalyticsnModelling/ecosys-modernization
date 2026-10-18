// Use the native managed TypeScript runtime and its existing permission pipeline.
import path from 'node:path';
import fs from 'node:fs';
import {executionRoots} from './execution-isolation.mjs';
import {pathToFileURL} from 'node:url';
const runtime = process.env.DSH_WATCHDOG_RUNTIME ?? path.resolve(import.meta.dirname, '../../runtime');
const {default:NodePtcRuntime} = await import(pathToFileURL(path.join(runtime,
  'node_modules/@deepseek-ai/dsh-ptc-runtime-node/lib/index.js')));

export default class ContinuousCodeRuntime extends NodePtcRuntime {
  constructor(ctx,config) {
    const base=process.env.DSH_WATCHDOG_ROOT;
    if(!base||!path.isAbsolute(base))throw Error('Code runtime requires an absolute private launch root');
    const bootstrap=path.join(base,'code-runtime','process.mjs');
    fs.mkdirSync(path.dirname(bootstrap),{recursive:true});
    const original=fs.readFileSync(path.join(runtime,'node_modules/@deepseek-ai/dsh-ptc-runtime-node/lib/process.js'),'utf8');
    const marker='const STARTUP_ENVIRONMENT_NAMES = new Set([';
    if(original.split(marker).length!==2)throw Error('Unverified native code bootstrap environment contract');
    const source=original.replace(marker,marker+'\n "TMPDIR", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "UV_CACHE_DIR", "HF_HOME",');
    fs.writeFileSync(bootstrap,source,{mode:0o600});
    super(ctx,{...config,bootstrapPath:bootstrap});
  }
  resolve(request) {
    // Native null explicitly disables the elapsed deadline, including nested calls.
    // Keep native process isolation, memory/output limits, sandbox and cancellation.
    const root=executionRoots.getStore();
    let program=request.program;
    if(root) {
      const environment={};
      for(const [key,sub] of Object.entries({TMPDIR:'tmp',TEMP:'tmp',TMP:'tmp',XDG_CACHE_HOME:'cache',
        XDG_CONFIG_HOME:'config',XDG_DATA_HOME:'data',XDG_STATE_HOME:'state',UV_CACHE_DIR:'uv-cache',HF_HOME:'hf-cache'})){
        const directory=path.join(root,sub);fs.mkdirSync(directory,{recursive:true});environment[key]=directory;
      }
      program=`Object.assign(process.env,${JSON.stringify(environment)});\n${program}`;
    }
    return super.resolve({...request,program,timeoutMs:null});
  }
}

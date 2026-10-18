import fs from 'node:fs';
import path from 'node:path';
import {AsyncLocalStorage} from 'node:async_hooks';
import {sessionRoot} from './session-paths.mjs';
export const name='isolated-execution-environment';
export const inject=['tools','shell','shellEnv'];
export const executionRoots=new AsyncLocalStorage();
export function apply(ctx) {
  const owners=executionRoots;
  const base=process.env.DSH_WATCHDOG_ROOT;
  const rootFor=exec=>{
    if(!exec.agent?.session)throw Error('Shell execution lacks native session ownership');
    return sessionRoot(base,exec.agent.session.id);
  };
  ctx.shellEnv.register({name:'watchdog-session-paths',variables:{
    DSH_WATCHDOG_ROOT:{description:'Private notes/state directory of this native agent'},
    DSH_WATCHDOG_LAUNCH_ROOT:{description:'Private namespace of the supervising launch'}},
    resolve:exec=>({DSH_WATCHDOG_ROOT:rootFor(exec),DSH_WATCHDOG_LAUNCH_ROOT:base})});
  ctx.on('tools/execute',(exec,next)=>owners.run(rootFor(exec),next),{global:true});
  const environment=(root,existing)=>{
    const env={...existing};
    for(const [key,sub] of Object.entries({TMPDIR:'tmp',XDG_CACHE_HOME:'cache',XDG_CONFIG_HOME:'config',
      XDG_DATA_HOME:'data',XDG_STATE_HOME:'state',UV_CACHE_DIR:'uv-cache',HF_HOME:'hf-cache',
      NODE_COMPILE_CACHE:'node-cache',MPLCONFIGDIR:'matplotlib',TORCH_HOME:'torch-cache'})){
      const dir=path.join(root,sub);fs.mkdirSync(dir,{recursive:true});env[key]=dir;
    }
    return env;
  };
  const original=ctx.shell.resolve.bind(ctx.shell);
  ctx.shell.resolve=request=>{
    const root=owners.getStore();
    return original(root?{...request,env:environment(root,request.env)}:request);
  };
  ctx.inject(['subprocess'],runtimeCtx=>{
    const spawn=runtimeCtx.subprocess.spawn.bind(runtimeCtx.subprocess);
    runtimeCtx.subprocess.spawn=request=>{
      const root=owners.getStore();
      return spawn(root?{...request,env:environment(root,request.env)}:request);
    };
  });
}

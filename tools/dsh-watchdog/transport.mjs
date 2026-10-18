import {AsyncLocalStorage} from 'node:async_hooks';
export const name='isolated-local-transport';
export const inject=['llm'];
export function apply(ctx) {
  const requests=new AsyncLocalStorage();
  const previous=globalThis.fetch;
  const wrapped=(input,init)=>{
    const route=requests.getStore();
    const url=new URL(typeof input==='string'||input instanceof URL?input:input.url);
    const endpoint=process.env.DSH_ISOLATED_ENDPOINT;
    if(route&&endpoint&&url.origin===new URL(endpoint).origin) {
      if(!route.sessionId)throw Error('Isolated local request lacks a native session identity');
      const headers=new Headers(init?.headers??(input instanceof Request?input.headers:undefined));
      headers.set('X-DSH-Session',route.sessionId);
      headers.set('X-DSH-Purpose',route.purpose??'inference');
      return previous(input,{...init,headers});
    }
    return previous(input,init);
  };
  ctx.effect(()=>{globalThis.fetch=wrapped;return()=>{if(globalThis.fetch===wrapped)globalThis.fetch=previous;};});
  ctx.on('llm/stream',(options,next)=>{
    if(options.provider!=='mlx-local')return next();
    return {async *[Symbol.asyncIterator]() {
      const iterator=next()[Symbol.asyncIterator]();
      const route={sessionId:options.sessionId,purpose:options.purpose};
      try {
        while(true){const item=await requests.run(route,()=>iterator.next());if(item.done)return;yield item.value;}
      }finally{if(iterator.return)await requests.run(route,()=>iterator.return());}
    }};
  },{global:true});
}

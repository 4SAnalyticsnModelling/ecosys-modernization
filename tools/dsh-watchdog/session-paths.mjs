import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {atomic,readState} from './core.mjs';
export function sessionKey(id) {
  if(typeof id!=='string'||!id||id.length>1024)throw Error('Missing native session identity');
  return crypto.createHash('sha256').update(id).digest('hex');
}
export function sessionRoot(base,id) {
  if(readState(path.join(base,'state.json')).layout!=='per-agent-v1')return base;
  const parent=path.join(base,'agents');fs.mkdirSync(parent,{recursive:true});
  const root=path.join(parent,sessionKey(id));
  if(!fs.existsSync(root)) {
    fs.mkdirSync(root,{mode:0o700});
    for(const file of ['progress.md','decisions.md','issues.md'])
      fs.copyFileSync(path.join(import.meta.dirname,'templates',file),path.join(root,file));
    atomic(path.join(root,'identity.json'),{sessionId:id});
    atomic(path.join(root,'state.json'),{schema:1,sessions:{}});
  }
  const identity=JSON.parse(fs.readFileSync(path.join(root,'identity.json'),'utf8'));
  if(identity.sessionId!==id)throw Error('Session namespace identity mismatch');
  readState(path.join(root,'state.json'));
  return root;
}

export async function snapshotSession(base,id,destination,persistence) {
  if(readState(path.join(base,'state.json')).layout!=='per-agent-v1') {
    fs.cpSync(path.join(base,'sessions'),destination,{recursive:true});return;
  }
  const file=await persistence.resolveCurrentLog(id);
  if(!file)throw Error('Target native session artifact missing');
  const source=path.dirname(file),relative=path.relative(path.join(base,'sessions'),source);
  if(!relative||relative.startsWith('..')||path.isAbsolute(relative))throw Error('Session artifact escapes its store');
  fs.cpSync(source,path.join(destination,relative),{recursive:true});
}

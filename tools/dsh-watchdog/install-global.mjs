// Explicitly requested global deployment. Originals and receipts stay in repo.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
for (const file of ['core.mjs','plugin.mjs','hygiene.mjs','global-context.mjs'])
  execFileSync('node',['--check',path.join(import.meta.dirname,file)]);
execFileSync('python3',['-c',"import ast,sys; ast.parse(open(sys.argv[1]).read())",path.join(import.meta.dirname,'global-supervisor.py')],
  {env:{...process.env,PYTHONDONTWRITEBYTECODE:'1'}});
const repo=path.resolve(import.meta.dirname,'../..');
const installed=path.join(os.homedir(),'.local/share/deepseek-harness');
const target=path.join(installed,'tool-env/watchdog');
const backup=path.join(repo,'watchdog/global-backup');
fs.mkdirSync(backup,{recursive:true});fs.mkdirSync(target,{recursive:true});
const files=[path.join(installed,'configure-context.mjs'),path.join(installed,'configure.mjs'),
 path.join(os.homedir(),'.local/bin/dsh'),path.join(os.homedir(),'.local/bin/dst')];
for(const name of fs.readdirSync(path.join(os.homedir(),'.dsh/profiles'))) {
 const file=path.join(os.homedir(),'.dsh/profiles',name,'cordis.patch.yml');
 if(fs.existsSync(file))files.push(file);
}
const receipt=[];
for(const file of files) {
 const saved=path.join(backup,crypto.createHash('sha256').update(file).digest('hex').slice(0,12)+'-'+path.basename(file));
 if(!fs.existsSync(saved))fs.copyFileSync(file,saved);
 receipt.push({file,backup:saved,beforeHash:crypto.createHash('sha256').update(fs.readFileSync(saved)).digest('hex')});
}
for(const file of ['core.mjs','plugin.mjs','hygiene.mjs','global-context.mjs','global-supervisor.py','AGENTS.md'])
 fs.copyFileSync(path.join(import.meta.dirname,file),path.join(target,file));
fs.cpSync(path.join(import.meta.dirname,'templates'),path.join(target,'templates'),{recursive:true});
fs.writeFileSync(path.join(installed,'configure-context.mjs'),"export {configureContext} from './tool-env/watchdog/global-context.mjs';\n");
const configureFile=path.join(installed,'configure.mjs');
let source=fs.readFileSync(configureFile,'utf8');
if(!source.includes('watchdogGlobalSync')) source += "\nconst {syncProfiles:watchdogGlobalSync} = await import('./tool-env/watchdog/global-context.mjs');\nwatchdogGlobalSync(local,{provider:'mlx-local',model:preferred.id});\n";
fs.writeFileSync(configureFile,source);
for(const name of ['dsh','dst']) {
 const file=path.join(os.homedir(),'.local/bin',name), original=path.join(target,'original-'+name);
 if(!fs.existsSync(original)) fs.copyFileSync(file,original);
 fs.chmodSync(original,0o755);
 const q=value=>"'"+value.replaceAll("'","'\\''")+"'";
 fs.writeFileSync(file,`#!/bin/zsh\n# Global DeepSeek-only watchdog (original launcher preserved).\nfor arg in "$@"; do\n case "$arg" in --help|-h|--version|-V|help|version|doctor|update|plugin|--dump-*) exec ${q(original)} "$@";; esac\ndone\nif [[ "\${DSH_WATCHDOG_SUPERVISED:-}" == 1 ]]; then exec ${q(original)} "$@"; fi\nexec /usr/bin/python3 ${q(path.join(target,'global-supervisor.py'))} ${q(original)} "$@"\n`,{mode:0o755});
}
execFileSync('node',[path.join(installed,'configure.mjs')],{cwd:repo,env:{...process.env,DSH_INSTALLED_ROOT:installed},stdio:'inherit'});
for(const item of receipt)item.afterHash=crypto.createHash('sha256').update(fs.readFileSync(item.file)).digest('hex');
fs.writeFileSync(path.join(repo,'watchdog/global-install-receipt.json'),JSON.stringify({at:new Date().toISOString(),target,files:receipt},null,2));
console.log('Global watchdog installed: dsh + dst/dsh-tui, all installed profiles, all catalog models.');

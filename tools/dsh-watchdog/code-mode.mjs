// Use the native managed TypeScript runtime and its existing permission pipeline.
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const runtime = process.env.DSH_WATCHDOG_RUNTIME ?? path.resolve(import.meta.dirname, '../../runtime');
const {default:NodePtcRuntime} = await import(pathToFileURL(path.join(runtime,
  'node_modules/@deepseek-ai/dsh-ptc-runtime-node/lib/index.js')));

export default class ContinuousCodeRuntime extends NodePtcRuntime {
  resolve(request) {
    // Native null explicitly disables the elapsed deadline, including nested calls.
    // Keep native process isolation, memory/output limits, sandbox and cancellation.
    return super.resolve({...request, timeoutMs:null});
  }
}

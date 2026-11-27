// The host of a program for wasm64 on Node.js 24 or later: `node name.mjs arguments...` (this file and `wasm_host_core.js`, as `cross_link` joins them).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = fileURLToPath(import.meta.url);
const wasmPath = process.env.STATIC_RUNTIME_WASM || path.join(path.dirname(here), path.basename(here, '.mjs') + '.wasm');
const sleepCell = new Int32Array(new SharedArrayBuffer(4));
const platform = {
  fs, os,
  process: { env: process.env, pid: process.pid, cwd: () => process.cwd(), chdir: (d) => process.chdir(d), hrtime: { bigint: () => process.hrtime.bigint() }, onExit: (f) => process.on('exit', f) },
  sleep: (ms) => { Atomics.wait(sleepCell, 0, 0, ms); },
};
process.exitCode = runProgram(platform, fs.readFileSync(wasmPath), [wasmPath, ...process.argv.slice(2)]);


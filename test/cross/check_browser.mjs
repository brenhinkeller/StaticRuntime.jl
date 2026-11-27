// Runs the programs that `test/cross/build.jl` made for WebAssembly with the host for a browser (`exe.browser.mjs`, over files in memory), and compares what they do with what the native ones did:
//   node test/cross/check_browser.mjs <outdir>                 in Node.js (checks the host's logic)
//   BROWSER=/path/to/firefox node test/cross/check_browser.mjs <outdir>   in that browser, headless (Firefox, or Chrome: a program for `memory64` needs Firefox 134 or Chrome 133 or later)
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const outdir = process.argv[2];
const names = fs.readdirSync(outdir).sort().filter((n) => fs.existsSync(path.join(outdir, n, 'exe.browser.mjs')));
const wanted = (name) => { const dir = path.join(outdir, name); return [fs.readFileSync(path.join(dir, 'stdout'), 'utf8'), fs.readFileSync(path.join(dir, 'stderr'), 'utf8'), Number(fs.readFileSync(path.join(dir, 'status'), 'utf8'))]; };
let failed = 0;
function report(name, got) {
  const want = wanted(name), same = got.out === want[0] && got.err === want[1] && got.exitCode === want[2];
  console.log(same ? 'ok      ' : 'FAILED  ', name);
  if (!same) { failed++; console.log('   got ', JSON.stringify([got.out, got.err, got.exitCode, got.error]).slice(0, 400), '\n   want', JSON.stringify(want).slice(0, 400)); }
}

if (!process.env.BROWSER) {
  for (const name of names) {
    const dir = path.join(outdir, name);
    const { run } = await import(pathToFileURL(path.join(dir, 'exe.browser.mjs')).href);
    let out = '', err = '';
    const result = await run(fs.readFileSync(path.join(dir, 'exe.wasm')), { stdout: (t) => { out += t; }, stderr: (t) => { err += t; } });
    report(name, { out, err, exitCode: result.exitCode });
  }
  console.log(failed ? `${failed} failed` : 'all programs did what the native ones did');
  process.exit(failed ? 1 : 0);
}

// in a browser: a page served from here runs each program and sends what it did back
const page = `<!doctype html><meta charset=utf-8><title>programs</title><script type=module>
const names = ${JSON.stringify(names)};
for (const name of names) {
  let out = '', err = '', exitCode = null, error = null;
  try {
    const { run } = await import('/' + name + '/exe.browser.mjs');
    const result = await run('/' + name + '/exe.wasm', { stdout: (t) => { out += t; }, stderr: (t) => { err += t; } });
    exitCode = result.exitCode;
  } catch (e) { error = String(e); }
  await fetch('/result/' + name, { method: 'POST', body: JSON.stringify({ out, err, exitCode, error }) });
}
await fetch('/done', { method: 'POST', body: '' });
</script>`;
const types = { '.mjs': 'text/javascript', '.wasm': 'application/wasm', '.html': 'text/html' };
let browser;
const finish = (code) => { if (browser) browser.kill(); server.close(); process.exit(code); };
const server = http.createServer((req, res) => {
  if (req.method === 'POST') {
    let body = ''; req.on('data', (c) => { body += c; });
    req.on('end', () => { res.end('ok'); if (req.url === '/done') { console.log(failed ? `${failed} failed` : 'all programs did what the native ones did'); finish(failed ? 1 : 0); } else report(decodeURIComponent(req.url.slice('/result/'.length)), JSON.parse(body)); });
    return;
  }
  if (req.url === '/' || req.url === '/index.html') { res.setHeader('content-type', 'text/html'); return res.end(page); }
  const file = path.join(outdir, decodeURIComponent(req.url.split('?')[0]));
  if (!file.startsWith(path.resolve(outdir)) || !fs.existsSync(file)) { res.statusCode = 404; return res.end('no'); }
  res.setHeader('content-type', types[path.extname(file)] || 'application/octet-stream'); res.end(fs.readFileSync(file));
});
server.listen(0, '127.0.0.1', () => {
  const url = `http://127.0.0.1:${server.address().port}/`;
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'browser-profile-'));
  const isFirefox = /firefox/i.test(process.env.BROWSER);
  browser = spawn(process.env.BROWSER, isFirefox ? ['--headless', '--no-remote', '--profile', profile, url] : ['--headless=new', `--user-data-dir=${profile}`, '--no-first-run', url], { stdio: 'ignore' });
  setTimeout(() => { console.log('timed out'); finish(1); }, 10 * 60 * 1000);
});

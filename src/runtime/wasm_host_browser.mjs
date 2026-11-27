// The host of a program for wasm64 in a browser (or any JavaScript with WebAssembly `memory64` and exception handling, Deno and Bun included): this file and `wasm_host_core.js`, as `cross_link` joins them.
//
//   import { run } from './name.browser.mjs';
//   const result = await run('name.wasm', { args: ['--n', '10'], files: { '/data/input.csv': csvText }, stdout: (text) => log.append(text) });
//   result.exitCode, result.readFile('/out.txt') (bytes), result.list('/')
//
// The program runs where `run` is called, to its end, and the page does not respond meanwhile: in a Web Worker (`new Worker(url, { type: 'module' })`) that is not a problem. The files that the program has are
// in memory (`files`: the path of each, and its text or bytes), what it writes is in `result`, and standard input is the text or bytes of `stdin`. There are no processes and no sockets.

if (typeof Buffer === 'undefined') {               // (the part of Node's `Buffer` that the host uses)
  const encoder = new TextEncoder(), decoder = new TextDecoder();
  class Bytes extends Uint8Array {
    static from(x) { if (typeof x === 'string') { const a = encoder.encode(x); return new Bytes(a.buffer, a.byteOffset, a.length); } const a = Uint8Array.from(x); return new Bytes(a.buffer, a.byteOffset, a.length); }
    static alloc(n) { return new Bytes(n); }
    static concat(list) { let n = 0; for (const b of list) n += b.length; const out = new Bytes(n); let at = 0; for (const b of list) { out.set(b, at); at += b.length; } return out; }
    static byteLength(s) { return encoder.encode(s).length; }
    toString() { return decoder.decode(this); }
  }
  globalThis.Buffer = Bytes;
}

const fail = (code, syscall) => Object.assign(new Error(`${code}: ${syscall}`), { code });

// The functions of Node's `fs` that the host uses, over files in memory.
class MemoryFS {
  constructor(out, stdin) {
    this.constants = { O_RDONLY: 0, O_WRONLY: 1, O_RDWR: 2, O_CREAT: 0x40, O_EXCL: 0x80, O_TRUNC: 0x200, O_APPEND: 0x400 };
    this.nextIno = 2; this.root = this.node('dir', 0o755); this.fds = new Map(); this.nextFd = 3; this.cwdPath = '/';
    this.out = out; this.stdinBytes = stdin; this.stdinAt = 0;
    this.root.entries.set('tmp', this.node('dir', 0o777)); // (where `tempname` and `mktempdir` make theirs)
  }
  node(type, mode) { const now = Date.now(); return { type, mode, ino: this.nextIno++, data: new Uint8Array(0), size: 0, entries: type === 'dir' ? new Map() : null, target: '', atime: now, mtime: now, ctime: now }; }
  normalize(parts) { const out = []; for (const c of parts) { if (c === '' || c === '.') continue; if (c === '..') out.pop(); else out.push(c); } return out; }
  split(p) { return this.normalize((p.startsWith('/') ? p : this.cwdPath + '/' + p).split('/')); }
  lookup(path, follow = true) {                    // { parent, name, node (null if there is none), parts }
    let parts = this.split(path), depth = 0;
    for (;;) {
      let node = this.root, parent = null, name = '', restarted = false;
      for (let i = 0; i < parts.length; i++) {
        if (node.type !== 'dir') throw fail('ENOTDIR', path);
        const c = parts[i]; parent = node; name = c;
        const child = node.entries.get(c);
        if (!child) { if (i < parts.length - 1) throw fail('ENOENT', path); return { parent, name, node: null, parts }; }
        if (child.type === 'symlink' && (follow || i < parts.length - 1)) {
          if (++depth > 40) throw fail('ELOOP', path);
          const base = child.target.startsWith('/') ? [] : parts.slice(0, i);
          parts = this.normalize([...base, ...child.target.split('/'), ...parts.slice(i + 1)]); restarted = true; break;
        }
        node = child;
      }
      if (!restarted) return { parent, name, node, parts };
    }
  }
  existing(path, follow = true) { const r = this.lookup(path, follow); if (!r.node) throw fail('ENOENT', path); return r.node; }
  stats(n) {
    const type = n.type === 'dir' ? 0o040000 : n.type === 'symlink' ? 0o120000 : 0o100000, size = n.type === 'dir' ? 4096 : n.type === 'symlink' ? n.target.length : n.size, ns = (ms) => BigInt(Math.round(ms)) * 1000000n;
    return { dev: 1n, ino: BigInt(n.ino), nlink: n.type === 'dir' ? 2n : 1n, mode: BigInt(type | n.mode), uid: 1000n, gid: 1000n, rdev: 0n, size: BigInt(size), blksize: 4096n, blocks: BigInt(Math.ceil(size / 512)), atimeNs: ns(n.atime), mtimeNs: ns(n.mtime), ctimeNs: ns(n.ctime) };
  }
  // files: the other interface of the module, for the page
  put(path, data) {
    const bytes = typeof data === 'string' ? Buffer.from(data) : data, parts = this.split(path);
    let dir = this.root;
    for (const c of parts.slice(0, -1)) { let d = dir.entries.get(c); if (!d) { d = this.node('dir', 0o755); dir.entries.set(c, d); } dir = d; }
    const f = this.node('file', 0o644); f.data = Uint8Array.from(bytes); f.size = bytes.length; dir.entries.set(parts[parts.length - 1], f);
  }
  openSync(path, flags, mode = 0o666) {
    if (typeof flags === 'string') flags = { 'r': 0, 'r+': 2, 'w': 1 | 0x40 | 0x200, 'w+': 2 | 0x40 | 0x200, 'a': 1 | 0x40 | 0x400, 'a+': 2 | 0x40 | 0x400, 'wx': 1 | 0x40 | 0x200 | 0x80, 'wx+': 2 | 0x40 | 0x200 | 0x80, 'ax': 1 | 0x40 | 0x400 | 0x80, 'ax+': 2 | 0x40 | 0x400 | 0x80 }[flags];
    const r = this.lookup(path);
    let node = r.node;
    if (!node) {
      if (!(flags & 0x40)) throw fail('ENOENT', path);
      if (!r.parent) throw fail('ENOENT', path);
      node = this.node('file', mode & 0o777 & ~0o022); r.parent.entries.set(r.name, node);
    } else {
      if ((flags & 0x40) && (flags & 0x80)) throw fail('EEXIST', path);
      if (node.type === 'dir' && (flags & 3) !== 0) throw fail('EISDIR', path);
      if (node.type === 'file' && (flags & 0x200)) { node.data = new Uint8Array(0); node.size = 0; node.mtime = Date.now(); }
    }
    const fd = this.nextFd++;
    this.fds.set(fd, { node, append: !!(flags & 0x400), pos: 0 });
    return fd;
  }
  closeSync(fd) { if (!this.fds.delete(fd)) throw fail('EBADF', 'close'); }
  readSync(fd, buf, off, len, pos) {
    if (fd === 0) { const n = Math.min(len, this.stdinBytes.length - this.stdinAt); buf.set(this.stdinBytes.subarray(this.stdinAt, this.stdinAt + n), off); this.stdinAt += n; return n; }
    const rec = this.fds.get(fd); if (!rec) throw fail('EBADF', 'read');
    if (rec.node.type === 'dir') throw fail('EISDIR', 'read');
    const at = pos == null ? rec.pos : pos, n = Math.max(0, Math.min(len, rec.node.size - at));
    buf.set(rec.node.data.subarray(at, at + n), off);
    if (pos == null) rec.pos += n;
    return n;
  }
  writeSync(fd, data, off = 0, len, pos = null) {
    const bytes = typeof data === 'string' ? Buffer.from(data) : data.subarray(off, len === undefined ? undefined : off + len);
    if (fd === 1 || fd === 2) { this.out(fd, bytes); return bytes.length; }
    const rec = this.fds.get(fd); if (!rec) throw fail('EBADF', 'write');
    const n = rec.node, at = rec.append ? n.size : (pos == null ? rec.pos : pos), end = at + bytes.length;
    if (end > n.data.length) { const grown = new Uint8Array(Math.max(end, n.data.length * 2, 64)); grown.set(n.data.subarray(0, n.size)); n.data = grown; }
    n.data.set(bytes, at); n.size = Math.max(n.size, end); n.mtime = Date.now();
    if (pos == null) rec.pos = end;
    return bytes.length;
  }
  fstatSync(fd) { const rec = this.fds.get(fd); if (!rec) throw fail('EBADF', 'fstat'); return this.stats(rec.node); }
  statSync(path) { return this.stats(this.existing(path)); }
  lstatSync(path) { return this.stats(this.existing(path, false)); }
  accessSync(path) { this.existing(path); }
  readdirSync(path, options) {
    const n = this.existing(path); if (n.type !== 'dir') throw fail('ENOTDIR', path);
    const names = [...n.entries.keys()].sort();
    return options && options.withFileTypes ? names.map((name) => { const t = n.entries.get(name).type; return { name, isDirectory: () => t === 'dir', isFile: () => t === 'file', isSymbolicLink: () => t === 'symlink' }; }) : names;
  }
  mkdirSync(path, mode = 0o777) {
    const r = this.lookup(path, false);
    if (r.node) throw fail('EEXIST', path);
    if (!r.parent) throw fail('ENOENT', path);
    r.parent.entries.set(r.name, this.node('dir', mode & 0o777 & ~0o022));
  }
  rmdirSync(path) {
    const r = this.lookup(path, false);
    if (!r.node) throw fail('ENOENT', path);
    if (r.node.type !== 'dir') throw fail('ENOTDIR', path);
    if (r.node.entries.size > 0) throw fail('ENOTEMPTY', path);
    if (!r.parent) throw fail('EBUSY', path);
    r.parent.entries.delete(r.name);
  }
  unlinkSync(path) {
    const r = this.lookup(path, false);
    if (!r.node) throw fail('ENOENT', path);
    if (r.node.type === 'dir') throw fail('EISDIR', path);
    r.parent.entries.delete(r.name);
  }
  renameSync(a, b) {
    const from = this.lookup(a, false), to = this.lookup(b, false);
    if (!from.node) throw fail('ENOENT', a);
    if (!to.parent) throw fail('ENOENT', b);
    if (to.node && to.node.type === 'dir' && (from.node.type !== 'dir' || to.node.entries.size > 0)) throw fail(from.node.type === 'dir' ? 'ENOTEMPTY' : 'EISDIR', b);
    from.parent.entries.delete(from.name); to.parent.entries.set(to.name, from.node);
  }
  chmodSync(path, mode) { this.existing(path).mode = Number(mode) & 0o7777; }
  realpathSync(path) { const r = this.lookup(path); if (!r.node) throw fail('ENOENT', path); return '/' + r.parts.join('/'); }
  symlinkSync(target, path) {
    const r = this.lookup(path, false);
    if (r.node) throw fail('EEXIST', path);
    if (!r.parent) throw fail('ENOENT', path);
    const n = this.node('symlink', 0o777); n.target = target; r.parent.entries.set(r.name, n);
  }
  readlinkSync(path) { const n = this.existing(path, false); if (n.type !== 'symlink') throw fail('EINVAL', path); return n.target; }
  readFile(path) { const n = this.existing(path); if (n.type !== 'file') throw fail('EISDIR', path); return n.data.slice(0, n.size); }
  list(path = '/') { return this.readdirSync(path); }
}

export async function run(source, { args = [], env = {}, files = {}, stdin = '', stdout = (text) => console.log(text.replace(/\n$/, '')), stderr = (text) => console.error(text.replace(/\n$/, '')), cwd = '/' } = {}) {
  const bytes = source instanceof Uint8Array ? source : source instanceof ArrayBuffer ? new Uint8Array(source) : new Uint8Array(await (await (source instanceof Response ? source : fetch(source))).arrayBuffer());
  const decoders = { 1: new TextDecoder(), 2: new TextDecoder() }, sinks = { 1: stdout, 2: stderr };
  const memory = new MemoryFS((fd, chunk) => { const text = decoders[fd].decode(chunk, { stream: true }); if (text) sinks[fd](text); }, typeof stdin === 'string' ? new TextEncoder().encode(stdin) : stdin);
  for (const [path, data] of Object.entries(files)) memory.put(path, data);
  memory.cwdPath = '/' + memory.split(cwd).join('/');
  const exits = [], start = performance.now();
  const platform = {
    fs: memory,
    os: { hostname: () => 'browser', totalmem: () => 4 * 2 ** 30, freemem: () => 2 * 2 ** 30 },
    process: { env: { ...env }, pid: 1, cwd: () => memory.cwdPath, chdir: (d) => { const n = memory.existing(d); if (n.type !== 'dir') throw fail('ENOTDIR', d); memory.cwdPath = '/' + memory.lookup(d).parts.join('/'); }, hrtime: { bigint: () => BigInt(Math.round((performance.now() - start) * 1e6)) + 1000000000n }, onExit: (f) => exits.push(f) },
    sleep: (ms) => { const end = performance.now() + ms; while (performance.now() < end); },
  };
  const exitCode = runProgram(platform, bytes, ['program', ...args]);
  for (const f of exits) f();
  [1, 2].forEach((fd) => { const t = decoders[fd].decode(); if (t) sinks[fd](t); });
  return { exitCode, readFile: (path) => memory.readFile(path), list: (path) => memory.list(path), fs: memory };
}

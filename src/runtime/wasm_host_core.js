// The host of a program for wasm64: what a program has of a C library and of a system is in these functions, which the program imports (`env.name`), written for Node.js 24 or later
// (memory64 and 64-bit tables are on by default). Pointers and sizes are 64 bits: `BigInt`s here. Run: `node name.mjs [arguments]`.
// The functions are those of `WASM_HOST_FUNCTIONS` in src/cross.jl (the others are refused when the program is made). Not here: files, processes, threads.
// Not a module of its own: `cross_link` puts this function after a shell for the platform (`wasm_host_node.mjs`, `wasm_host_browser.mjs`), which gives it what the platform has: `P.fs` (the functions of
// Node's `fs` that are used here), `P.process` (`env`, `pid`, `cwd`, `chdir`, `hrtime.bigint`, `onExit`), `P.os` (`hostname`, `totalmem`, `freemem`) and `P.sleep(milliseconds)`.
function runProgram(P, wasmBytes, args) {
const { fs, os, process } = P;
const module = new WebAssembly.Module(wasmBytes);
let memory, instance;
const u8 = () => new Uint8Array(memory.buffer);
const dv = () => new DataView(memory.buffer);
const cstring = (p) => { const m = u8(); let e = Number(p); while (m[e] !== 0) e++; return Buffer.from(m.subarray(Number(p), e)); };
class Exit extends Error { constructor(code) { super('exit'); this.code = code; } }

// The allocator of the C library (`calloc`, `malloc`, `realloc`, `free`): blocks have a header of 16 bytes (their size) before them. Small sizes are rounded up to a power of two and freed blocks of each size
// are reused; a large block is a number of pages, freed blocks of each number of pages are reused. When there is no block of a size, the memory is grown. Memory that can't be grown is `NULL`, as in C,
// and the program (the runtime of Julia) stops with "Out of memory error".
const HEADER = 16n, PAGE = 65536n, LARGE = 1048576n;
let top = 0n, limit = 0n;                          // the end of what has been handed out, and of the memory that is there
const freeSmall = new Map(), freeLarge = new Map();  // size (or pages) => the addresses of the free blocks
let inUse = 0n, peak = 0n;
function growTo(bytes) {                           // false if the memory can't be grown (its limit, or the machine's)
  const pages = (bytes + PAGE - 1n) / PAGE;
  try { memory.grow(pages); } catch (e) { if (e instanceof RangeError) return false; throw e; }
  limit = BigInt(memory.buffer.byteLength);
  return true;
}
function sizeClass(n) { let c = 32n; while (c < n) c <<= 1n; return c; }
function allocate(bytes) {                         // an address of `bytes` zeroed bytes, or 0n
  if (bytes < 0n) return 0n;
  const large = bytes + HEADER > LARGE;
  const size = large ? ((bytes + HEADER + PAGE - 1n) / PAGE) * PAGE : sizeClass(bytes + HEADER);
  const key = large ? size / PAGE : size;
  const list = (large ? freeLarge : freeSmall).get(key);
  let block;
  if (list && list.length) {
    block = list.pop();
    u8().fill(0, Number(block + HEADER), Number(block + size));
  } else {
    if (top + size > limit) {
      const want = size > 4194304n ? size : 4194304n; // (at least 4 MiB at a time)
      if (!growTo(want)) { if (!growTo(size)) return 0n; }
    }
    block = top; top += size;                      // (new pages are zero)
  }
  dv().setBigUint64(Number(block), size, true);
  inUse += size; if (inUse > peak) peak = inUse;
  return block + HEADER;
}
function release(p) {
  if (p === 0n) return;
  const block = p - HEADER, size = dv().getBigUint64(Number(block), true);
  const large = size > LARGE, key = large ? size / PAGE : size, map = large ? freeLarge : freeSmall;
  if (!map.has(key)) map.set(key, []);
  map.get(key).push(block);
  inUse -= size;
}
const blockSize = (p) => dv().getBigUint64(Number(p - HEADER), true) - HEADER;

// a stdio stream is the number of its file descriptor, which the program has as the value of `stdout`, `stderr`, `stdin`
let stdoutBuffer = [];
const flushStdout = () => { if (stdoutBuffer.length) { fs.writeSync(1, Buffer.concat(stdoutBuffer)); stdoutBuffer = []; } };
function writeFd(fd, bytes) {
  const b = Buffer.from(bytes);
  const rec = files.get(fd);
  if (rec) return writeFile(rec, fd, b);
  if (fd === 1) { stdoutBuffer.push(b); if (stdoutBuffer.length > 64) flushStdout(); }
  else { flushStdout(); fs.writeSync(fd, b); }
  return b.length;
}

function format(fmt, vaList) {                     // `printf`'s arguments are in a buffer of naturally aligned slots
  const s = cstring(fmt).toString();
  let offset = Number(vaList), result = '';
  const align = (a) => { offset = Math.ceil(offset / a) * a; };
  for (let i = 0; i < s.length; i++) {
    if (s[i] !== '%') { result += s[i]; continue; }
    i++;
    let long = false, precision = null, width = '';
    while (/[0-9-]/.test(s[i])) { width += s[i]; i++; }
    if (s[i] === '.') { i++; precision = ''; while (/[0-9]/.test(s[i])) { precision += s[i]; i++; } }
    while (s[i] === 'l' || s[i] === 'z' || s[i] === 'j') { long = true; i++; }
    switch (s[i]) {
      case 'd': case 'i': if (long) { align(8); result += dv().getBigInt64(offset, true); offset += 8; } else { align(4); result += dv().getInt32(offset, true); offset += 4; } break;
      case 'u': if (long) { align(8); result += dv().getBigUint64(offset, true); offset += 8; } else { align(4); result += dv().getUint32(offset, true); offset += 4; } break;
      case 'x': if (long) { align(8); result += dv().getBigUint64(offset, true).toString(16); offset += 8; } else { align(4); result += dv().getUint32(offset, true).toString(16); offset += 4; } break;
      case 's': { align(8); const p = dv().getBigInt64(offset, true); offset += 8; result += cstring(p).toString(); break; }
      case 'c': align(4); result += String.fromCharCode(dv().getInt32(offset, true)); offset += 4; break;
      case 'f': case 'g': case 'e': { align(8); const x = dv().getFloat64(offset, true); offset += 8; result += precision !== null ? x.toFixed(Number(precision || 0)) : String(x); break; }
      case '%': result += '%'; break;
      default: result += '%' + s[i];
    }
  }
  return Buffer.from(result);
}

// 128-bit integers: the code generator calls these (compiler-rt's) for the operations that WebAssembly has no instruction for. An `i128` is two 64-bit halves (low, high), and a result is
// written where the first argument points.
const MASK128 = (1n << 128n) - 1n, MASK64 = (1n << 64n) - 1n;
const toU128 = (lo, hi) => ((BigInt.asUintN(64, hi) << 64n) | BigInt.asUintN(64, lo));
const toS128 = (lo, hi) => BigInt.asIntN(128, toU128(lo, hi));
const put128 = (ret, v) => { const u = BigInt.asUintN(128, v); dv().setBigUint64(Number(ret), u & MASK64, true); dv().setBigUint64(Number(ret) + 8, u >> 64n, true); };
const builtins = {
  __multi3: (ret, al, ah, bl, bh) => put128(ret, toU128(al, ah) * toU128(bl, bh)),
  __udivti3: (ret, al, ah, bl, bh) => put128(ret, toU128(al, ah) / toU128(bl, bh)),
  __umodti3: (ret, al, ah, bl, bh) => put128(ret, toU128(al, ah) % toU128(bl, bh)),
  __divti3: (ret, al, ah, bl, bh) => put128(ret, toS128(al, ah) / toS128(bl, bh)),
  __modti3: (ret, al, ah, bl, bh) => put128(ret, toS128(al, ah) % toS128(bl, bh)),
  __ashlti3: (ret, lo, hi, n) => put128(ret, toU128(lo, hi) << BigInt(n)),
  __lshrti3: (ret, lo, hi, n) => put128(ret, toU128(lo, hi) >> BigInt(n)),
  __ashrti3: (ret, lo, hi, n) => put128(ret, toS128(lo, hi) >> BigInt(n)),
  __floatuntidf: (lo, hi) => Number(toU128(lo, hi)),
  __floattidf: (lo, hi) => Number(toS128(lo, hi)),
  __fixunsdfti: (ret, x) => put128(ret, BigInt(Math.trunc(x))),
  __fixdfti: (ret, x) => put128(ret, BigInt(Math.trunc(x))),
};

// the math library: `fma` is exact (the code generator calls it for `muladd` and `fma` where the target has no instruction); the others are JavaScript's, which are not always the last digit of glibc's
// (Julia's own functions of the real numbers, `sin`, `exp`, `log`, are Julia code, and are in the program)
function decodeDouble(x) {
  const d = new DataView(new ArrayBuffer(8)); d.setFloat64(0, x);
  const hi = d.getUint32(0), lo = d.getUint32(4), e = (hi >>> 20) & 0x7ff;
  let m = (BigInt(hi & 0xfffff) << 32n) | BigInt(lo), exp;
  if (e === 0) exp = -1074; else { m |= 1n << 52n; exp = e - 1075; }
  return [(hi >>> 31) ? -m : m, exp];
}
function roundedDouble(S, e) {                      // the double that is nearest S * 2^e (ties to even)
  const negative = S < 0n; let A = negative ? -S : S;
  const shift = A.toString(2).length - 53;
  let exp = e;
  if (shift > 0) {
    const rest = A & ((1n << BigInt(shift)) - 1n), half = 1n << BigInt(shift - 1);
    A >>= BigInt(shift); exp += shift;
    if (rest > half || (rest === half && (A & 1n))) A += 1n;
  }
  const half1 = Math.trunc(exp / 2);
  const r = Number(A) * Math.pow(2, half1) * Math.pow(2, exp - half1);
  return negative ? -r : r;
}
function fma(a, b, c) {
  if (!isFinite(a) || !isFinite(b) || !isFinite(c) || a === 0 || b === 0) return a * b + c;
  const [ma, ea] = decodeDouble(a), [mb, eb] = decodeDouble(b);
  const P = ma * mb, pe = ea + eb;
  let C = 0n, ce = pe;
  if (c !== 0) [C, ce] = decodeDouble(c);
  const e = Math.min(pe, ce);
  const S = (P << BigInt(pe - e)) + (C << BigInt(ce - e));
  return S === 0n ? a * b + c : roundedDouble(S, e);
}
const libm = {
  fma, fmaf: (a, b, c) => Math.fround(fma(a, b, c)),
  pow: Math.pow, fmod: (a, b) => a % b, sin: Math.sin, cos: Math.cos, tan: Math.tan, asin: Math.asin, acos: Math.acos, atan: Math.atan, atan2: Math.atan2,
  sinh: Math.sinh, cosh: Math.cosh, tanh: Math.tanh, exp: Math.exp, exp2: (x) => Math.pow(2, x), log: Math.log, log2: Math.log2, log10: Math.log10,
  cbrt: Math.cbrt, hypot: Math.hypot, expm1: Math.expm1, log1p: Math.log1p,
  asinh: Math.asinh, acosh: Math.acosh, atanh: Math.atanh, exp10: (x) => Math.pow(10, x),
  erf: (x) => erfFunction(x), erfc: (x) => erfcFunction(x), tgamma: (x) => gammaFunction(x), lgamma: (x) => lgammaFunction(x),
  lgamma_r: (x, signPtr) => { dv().setInt32(Number(signPtr), x < 0 && Math.floor(x) % 2 !== 0 ? -1 : 1, true); return lgammaFunction(x); },
};

// The error function and the gamma function: series and continued fractions, accurate to a few units of the last digit or two (the ones of a C library are not these: the last digits can differ).
function erfFunction(x) {
  if (Number.isNaN(x)) return NaN;
  const a = Math.abs(x);
  if (a >= 6) return Math.sign(x);
  if (a > 2.5) return Math.sign(x) * (1 - erfcLarge(a));
  let term = a, sum = a;                          // erf x = 2/sqrt(pi) * sum_n (-1)^n x^(2n+1) / (n! (2n+1))
  for (let n = 1; n < 200; n++) { term *= -a * a / n; const add = term / (2 * n + 1); sum += add; if (Math.abs(add) < 1e-17 * Math.abs(sum)) break; }
  return Math.sign(x) * 2 / Math.sqrt(Math.PI) * sum;
}
function erfcLarge(x) {                           // the continued fraction (Lentz), for x > 0.5
  const tiny = 1e-300; let f = x, C = x, D = 0;
  for (let n = 1; n < 500; n++) { const an = n / 2; D = x + an * D; D = D === 0 ? tiny : 1 / D; C = x + an / C; if (C === 0) C = tiny; const delta = C * D; f *= delta; if (Math.abs(delta - 1) < 1e-16) break; }
  return Math.exp(-x * x) / (f * Math.sqrt(Math.PI));
}
function erfcFunction(x) {
  if (Number.isNaN(x)) return NaN;
  if (x < -6) return 2;
  if (x > 27) return 0;
  if (x >= 1) return erfcLarge(x);
  return 1 - erfFunction(x);
}
const LANCZOS = [0.99999999999980993, 676.5203681218851, -1259.1392167224028, 771.32342877765313, -176.61502916214059, 12.507343278686905, -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7];
function gammaFunction(x) {
  if (Number.isNaN(x)) return NaN;
  if (x === 0) return 1 / x;
  if (x < 0 && Number.isInteger(x)) return NaN;
  if (x === Infinity) return Infinity;
  if (x === -Infinity) return NaN;
  if (Number.isInteger(x) && x <= 171) { let r = 1; for (let i = 2; i < x; i++) r *= i; return r; }
  if (x < 0.5) return Math.PI / (Math.sin(Math.PI * x) * gammaFunction(1 - x));
  if (x > 171.7) return Infinity;
  x -= 1;
  let a = LANCZOS[0]; const t = x + 7.5;
  for (let i = 1; i < 9; i++) a += LANCZOS[i] / (x + i);
  return Math.sqrt(2 * Math.PI) * Math.pow(t, x + 0.5) * Math.exp(-t) * a;
}
function lgammaFunction(x) {
  if (Number.isNaN(x)) return NaN;
  if (x === Infinity || x === -Infinity) return Infinity;
  if (x <= 0 && Number.isInteger(x)) return Infinity;
  if (x < 0.5) return Math.log(Math.PI / Math.abs(Math.sin(Math.PI * x))) - lgammaFunction(1 - x);
  let shift = 0;                                   // (the recurrence moves x to where the series of Stirling is accurate)
  while (x < 15) { shift += Math.log(x); x += 1; }
  const x2 = 1 / (x * x);
  const series = (1 / 12 - x2 * (1 / 360 - x2 * (1 / 1260 - x2 * (1 / 1680 - x2 * (1 / 1188 - x2 * (691 / 360360 - x2 / 156)))))) / x;
  return (x - 0.5) * Math.log(x) - x + 0.5 * Math.log(2 * Math.PI) + series - shift;
}

// Files, directories and the environment, with the functions of Node's `fs`. A stdio stream (`FILE*`) is the number of its file descriptor, as for the standard streams; each open file has a position of
// its own (Node has no `lseek`: reads and writes are at it), and reads are in blocks. The layouts are those of Linux on x86-64 (`struct stat`, `struct dirent`: the program is made with those), and the
// error numbers are Linux's, whatever the system that Node is on.
const ERRNO = { EPERM: 1, ENOENT: 2, EIO: 5, EBADF: 9, EAGAIN: 11, ENOMEM: 12, EACCES: 13, EBUSY: 16, EEXIST: 17, EXDEV: 18, ENOTDIR: 20, EISDIR: 21, EINVAL: 22, EMFILE: 24, EFBIG: 27, ENOSPC: 28,
                ESPIPE: 29, EROFS: 30, ENAMETOOLONG: 36, ENOTEMPTY: 39, ELOOP: 40 };
const STRERROR = { 0: 'Success', 1: 'Operation not permitted', 2: 'No such file or directory', 5: 'Input/output error', 9: 'Bad file descriptor', 11: 'Resource temporarily unavailable', 12: 'Cannot allocate memory',
                   13: 'Permission denied', 16: 'Device or resource busy', 17: 'File exists', 18: 'Invalid cross-device link', 20: 'Not a directory', 21: 'Is a directory', 22: 'Invalid argument',
                   24: 'Too many open files', 27: 'File too large', 28: 'No space left on device', 29: 'Illegal seek', 30: 'Read-only file system', 36: 'File name too long', 39: 'Directory not empty',
                   40: 'Too many levels of symbolic links' };
let errnoPtr = 0n;
const fail = (e) => { dv().setInt32(Number(errnoPtr), ERRNO[e && e.code] || 5, true); return -1; };
const pathOf = (p) => cstring(p).toString();
const files = new Map();                           // fd => { pos, block, blockStart, blockLength, append }
const BLOCK = 65536;
const record = (fd, append = false) => { files.set(fd, { pos: 0, block: null, blockStart: 0, blockLength: 0, append }); return BigInt(fd); };
const modeFlags = (m) => ({ 'r': 'r', 'rb': 'r', 'r+': 'r+', 'rb+': 'r+', 'r+b': 'r+', 'w': 'w', 'wb': 'w', 'w+': 'w+', 'wb+': 'w+', 'w+b': 'w+', 'a': 'a', 'ab': 'a', 'a+': 'a+', 'ab+': 'a+', 'a+b': 'a+' }[m]);
const dirs = new Map();                            // the open directories: handle => { entries, next, entry }
let nextDir = 1n;
function putStat(st, buf) {                        // `struct stat` of Linux on x86-64
  const d = dv(), b = Number(buf);
  u8().fill(0, b, b + 144);
  d.setBigUint64(b + 0, BigInt(st.dev), true); d.setBigUint64(b + 8, BigInt(st.ino), true); d.setBigUint64(b + 16, BigInt(st.nlink), true);
  d.setUint32(b + 24, Number(st.mode), true); d.setUint32(b + 28, Number(st.uid), true); d.setUint32(b + 32, Number(st.gid), true);
  d.setBigUint64(b + 40, BigInt(st.rdev), true); d.setBigInt64(b + 48, BigInt(st.size), true);
  d.setBigInt64(b + 56, BigInt(st.blksize), true); d.setBigInt64(b + 64, BigInt(st.blocks), true);
  for (const [off, ns] of [[72, st.atimeNs], [88, st.mtimeNs], [104, st.ctimeNs]]) { d.setBigInt64(b + off, ns / 1000000000n, true); d.setBigInt64(b + off + 8, ns % 1000000000n, true); }
}
function putTm(seconds, tm, utc) {                // `struct tm` of Linux: nine ints, the offset from UTC (`long`) and the name of the zone
  const d = new Date(seconds * 1000), at = Number(tm), v = dv();
  const parts = utc ? [d.getUTCSeconds(), d.getUTCMinutes(), d.getUTCHours(), d.getUTCDate(), d.getUTCMonth(), d.getUTCFullYear() - 1900, d.getUTCDay()] : [d.getSeconds(), d.getMinutes(), d.getHours(), d.getDate(), d.getMonth(), d.getFullYear() - 1900, d.getDay()];
  parts.forEach((x, i) => v.setInt32(at + 4 * i, x, true));
  const year = utc ? d.getUTCFullYear() : d.getFullYear(), start = utc ? Date.UTC(year, 0, 1) : new Date(year, 0, 1).getTime();
  v.setInt32(at + 28, Math.floor((d.getTime() - start) / 86400000), true);
  const offset = utc ? 0 : -d.getTimezoneOffset() * 60;
  const january = new Date(year, 0, 1).getTimezoneOffset(), july = new Date(year, 6, 1).getTimezoneOffset();
  v.setInt32(at + 32, !utc && january !== july && d.getTimezoneOffset() === Math.min(january, july) ? 1 : 0, true);
  v.setBigInt64(at + 40, BigInt(offset), true);
  v.setBigInt64(at + 48, 0n, true);
}
const guard = (f) => { try { return f(); } catch (e) { return fail(e); } };
function fileBytes(rec, fd, n) {                   // up to `n` bytes at the position, from the block that is read
  if (!rec.block || rec.pos < rec.blockStart || rec.pos >= rec.blockStart + rec.blockLength) {
    rec.block = rec.block || Buffer.alloc(BLOCK);
    rec.blockStart = rec.pos; rec.blockLength = fs.readSync(fd, rec.block, 0, BLOCK, rec.pos);
  }
  const from = rec.pos - rec.blockStart, count = Math.min(n, rec.blockLength - from);
  return count > 0 ? rec.block.subarray(from, from + count) : Buffer.alloc(0);
}
function writeFile(rec, fd, bytes) {
  const written = fs.writeSync(fd, bytes, 0, bytes.length, rec.append ? null : rec.pos);
  rec.pos += written; rec.block = null; return written;
}
const filesEnv = {
  __errno_location: () => errnoPtr,
  strerror: (e) => { const text = Buffer.from((STRERROR[Number(e)] || `Unknown error ${e}`) + '\0'); const p = allocate(BigInt(text.length)); u8().set(text, Number(p)); return p; },
  open: (path, flags, va) => guard(() => {
    const acc = flags & 3, f = fs.constants;
    const nodeFlags = [f.O_RDONLY, f.O_WRONLY, f.O_RDWR][acc] | ((flags & 0x40) ? f.O_CREAT : 0) | ((flags & 0x200) ? f.O_TRUNC : 0) | ((flags & 0x400) ? f.O_APPEND : 0) | ((flags & 0x80) ? f.O_EXCL : 0);
    const fd = fs.openSync(pathOf(path), nodeFlags, (flags & 0x40) ? dv().getUint32(Number(va), true) : 0o666);
    record(fd, (flags & 0x400) !== 0); return fd;
  }),
  close: (fd) => guard(() => { files.delete(fd); fs.closeSync(fd); return 0; }),
  fopen: (path, mode) => { try { const m = modeFlags(cstring(mode).toString()); const fd = fs.openSync(pathOf(path), m, 0o666); return record(fd, m[0] === 'a'); } catch (e) { fail(e); return 0n; } },
  fdopen: (fd, mode) => { if (!files.has(Number(fd)) && fd > 2) record(Number(fd), cstring(mode).toString()[0] === 'a'); return BigInt(fd); },
  fclose: (stream) => guard(() => { const fd = Number(stream); files.delete(fd); fs.closeSync(fd); return 0; }),
  fgetc: (stream) => { const fd = Number(stream), rec = files.get(fd); try { if (!rec) { const b = Buffer.alloc(1); return fs.readSync(fd, b, 0, 1, null) === 1 ? b[0] : -1; } const b = fileBytes(rec, fd, 1); if (b.length === 0) return -1; rec.pos++; return b[0]; } catch (e) { fail(e); return -1; } },
  ungetc: (c, stream) => { const rec = files.get(Number(stream)); if (rec && rec.pos > 0 && c !== -1) { rec.pos--; return c; } return -1; },
  fread: (p, size, n, stream) => { const fd = Number(stream), rec = files.get(fd); if (!rec || size === 0n) return 0n; try { let want = Number(size * n), got = 0; while (want > 0) { const b = fileBytes(rec, fd, want); if (b.length === 0) break; u8().set(b, Number(p) + got); got += b.length; rec.pos += b.length; want -= b.length; } return BigInt(Math.floor(got / Number(size))); } catch (e) { fail(e); return 0n; } },
  fseek: (stream, offset, whence) => guard(() => { const fd = Number(stream), rec = files.get(fd); if (!rec) return fail({ code: 'ESPIPE' }); const base = whence === 0 ? 0 : whence === 1 ? rec.pos : Number(fs.fstatSync(fd).size); rec.pos = base + Number(offset); return 0; }),
  ftell: (stream) => { const rec = files.get(Number(stream)); return rec ? BigInt(rec.pos) : -1n; },
  stat: (path, buf) => guard(() => { putStat(fs.statSync(pathOf(path), { bigint: true }), buf); return 0; }),
  lstat: (path, buf) => guard(() => { putStat(fs.lstatSync(pathOf(path), { bigint: true }), buf); return 0; }),
  access: (path, mode) => guard(() => { fs.accessSync(pathOf(path), mode); return 0; }),
  mkdir: (path, mode) => guard(() => { fs.mkdirSync(pathOf(path), mode); return 0; }),
  rmdir: (path) => guard(() => { fs.rmdirSync(pathOf(path)); return 0; }),
  unlink: (path) => guard(() => { fs.unlinkSync(pathOf(path)); return 0; }),
  rename: (a, b) => guard(() => { fs.renameSync(pathOf(a), pathOf(b)); return 0; }),
  chmod: (path, mode) => guard(() => { fs.chmodSync(pathOf(path), mode); return 0; }),
  getcwd: (buf, size) => { const b = Buffer.from(process.cwd() + '\0'); if (buf === 0n) { const p = allocate(BigInt(b.length)); u8().set(b, Number(p)); return p; } if (BigInt(b.length) > size) { fail({ code: 'EINVAL' }); return 0n; } u8().set(b, Number(buf)); return buf; },
  chdir: (path) => guard(() => { process.chdir(pathOf(path)); return 0; }),
  realpath: (path, resolved) => { try { const b = Buffer.from(fs.realpathSync(pathOf(path)) + '\0'); const p = resolved === 0n ? allocate(BigInt(b.length)) : resolved; u8().set(b, Number(p)); return p; } catch (e) { fail(e); return 0n; } },
  mkstemp: (template) => { const t = pathOf(template); if (!t.endsWith('XXXXXX')) { fail({ code: 'EINVAL' }); return -1; } for (let tries = 0; tries < 100; tries++) { const name = t.slice(0, -6) + Array.from({ length: 6 }, () => 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'[Math.floor(Math.random() * 62)]).join(''); try { const fd = fs.openSync(name, 'wx+', 0o600); u8().set(Buffer.from(name.slice(-6)), Number(template) + Buffer.byteLength(t) - 6); record(fd); return fd; } catch (e) { if (e.code !== 'EEXIST') return fail(e); } } return fail({ code: 'EEXIST' }); },
  mkdtemp: (template) => { const t = pathOf(template); if (!t.endsWith('XXXXXX')) { fail({ code: 'EINVAL' }); return 0n; } for (let tries = 0; tries < 100; tries++) { const name = t.slice(0, -6) + Array.from({ length: 6 }, () => 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'[Math.floor(Math.random() * 62)]).join(''); try { fs.mkdirSync(name, 0o700); u8().set(Buffer.from(name.slice(-6)), Number(template) + Buffer.byteLength(t) - 6); return template; } catch (e) { if (e.code !== 'EEXIST') { fail(e); return 0n; } } } fail({ code: 'EEXIST' }); return 0n; },
  opendir: (path) => { try { const entries = fs.readdirSync(pathOf(path), { withFileTypes: true }); const h = nextDir++; dirs.set(h, { entries, next: 0, entry: allocate(280n) }); return h; } catch (e) { fail(e); return 0n; } },
  readdir: (handle) => { const d = dirs.get(handle); if (!d || d.next >= d.entries.length) return 0n; const e = d.entries[d.next++], at = Number(d.entry); u8().fill(0, at, at + 280); const type = e.isDirectory() ? 4 : e.isSymbolicLink() ? 10 : e.isFile() ? 8 : 0; u8()[at + 18] = type; u8().set(Buffer.from(e.name), at + 19); return d.entry; },
  closedir: (handle) => { const d = dirs.get(handle); if (d) { release(d.entry); dirs.delete(handle); } return 0; },
  getpid: () => process.pid,
  gettimeofday: (tv, tz) => { const ms = Date.now(); dv().setBigInt64(Number(tv), BigInt(Math.floor(ms / 1000)), true); dv().setBigInt64(Number(tv) + 8, BigInt((ms % 1000) * 1000), true); return 0; },
  time: (p) => { const t = BigInt(Math.floor(Date.now() / 1000)); if (p !== 0n) dv().setBigInt64(Number(p), t, true); return t; },
  gmtime_r: (timep, tm) => { putTm(Number(dv().getBigInt64(Number(timep), true)), tm, true); return tm; },
  localtime_r: (timep, tm) => { putTm(Number(dv().getBigInt64(Number(timep), true)), tm, false); return tm; },
  setenv: (name, value, overwrite) => { const n = cstring(name).toString(); if (overwrite === 0 && process.env[n] !== undefined) return 0; process.env[n] = cstring(value).toString(); return 0; },
  unsetenv: (name) => { delete process.env[cstring(name).toString()]; return 0; },
  gethostname: (buf, len) => { const b = Buffer.from(os.hostname() + '\0').subarray(0, Number(len)); u8().set(b, Number(buf)); return 0; },
  sysconf: (name) => ({ 2: 100n, 30: 65536n, 84: 1n, 83: 1n, 85: BigInt(Math.floor(os.totalmem() / 65536)), 86: BigInt(Math.floor(os.freemem() / 65536)) })[Number(name)] ?? -1n,
  symlink: (target, link) => guard(() => { fs.symlinkSync(pathOf(target), pathOf(link)); return 0; }),
  readlink: (path, buf, size) => { try { const b = Buffer.from(fs.readlinkSync(pathOf(path))).subarray(0, Number(size)); u8().set(b, Number(buf)); return BigInt(b.length); } catch (e) { fail(e); return -1n; } },
  getenv: (name) => { const v = process.env[cstring(name).toString()]; if (v === undefined) return 0n; const b = Buffer.from(v + '\0'); const p = allocate(BigInt(b.length)); u8().set(b, Number(p)); return p; },
};

const env = {
  ...builtins,
  ...libm,
  ...filesEnv,
  calloc: (n, size) => allocate(n * size),
  malloc: (size) => allocate(size),
  realloc: (p, size) => { if (p === 0n) return allocate(size); if (size === 0n) { release(p); return 0n; } const old = blockSize(p); if (size <= old) return p; const q = allocate(size); if (q === 0n) return 0n; u8().copyWithin(Number(q), Number(p), Number(p + old)); release(p); return q; },
  free: (p) => release(p),
  exit: (code) => { throw new Exit(code); },
  strlen: (p) => BigInt(cstring(p).length),
  memchr: (p, c, n) => { const i = u8().subarray(Number(p), Number(p + n)).indexOf(Number(c) & 255); return i < 0 ? 0n : p + BigInt(i); },
  memcmp: (a, b, n) => { const m = u8(); for (let i = 0; i < Number(n); i++) { const d = m[Number(a) + i] - m[Number(b) + i]; if (d !== 0) return d < 0 ? -1 : 1; } return 0; },
  memcpy: (d, s, n) => { u8().copyWithin(Number(d), Number(s), Number(s + n)); return d; },
  memmove: (d, s, n) => { u8().copyWithin(Number(d), Number(s), Number(s + n)); return d; },
  memset: (d, c, n) => { u8().fill(Number(c) & 255, Number(d), Number(d + n)); return d; },
  write: (fd, p, n) => BigInt(writeFd(Number(fd), u8().slice(Number(p), Number(p + n)))),
  fwrite: (p, size, n, stream) => { writeFd(Number(stream), u8().slice(Number(p), Number(p + size * n))); return n; },
  fputc: (c, stream) => { writeFd(Number(stream), [Number(c) & 255]); return c; },
  puts: (p) => { writeFd(1, Buffer.concat([cstring(p), Buffer.from('\n')])); return 1; },
  printf: (fmt, va) => { const b = format(fmt, va); writeFd(1, b); return b.length; },
  fflush: (stream) => { flushStdout(); return 0; },
  clock_gettime: (clock, ts) => {                  // (the clock of the process for the monotonic one, the time of day for the other)
    const ns = clock === 0 ? BigInt(Date.now()) * 1000000n : process.hrtime.bigint();
    dv().setBigInt64(Number(ts), ns / 1000000000n, true); dv().setBigInt64(Number(ts) + 8, ns % 1000000000n, true); return 0;
  },
  getentropy: (p, n) => { const b = new Uint8Array(Number(n)); globalThis.crypto.getRandomValues(b); u8().set(b, Number(p)); return 0; },
  nanosleep: (req, rem) => { const sec = dv().getBigInt64(Number(req), true), ns = dv().getBigInt64(Number(req) + 8, true); P.sleep(Number(sec) * 1000 + Number(ns) / 1e6); return 0; },
  _setjmp: (buf) => 0,
};

// (STATIC_RUNTIME_WASM_TRACE=1: each call of the host, on the standard error)
if (process.env.STATIC_RUNTIME_WASM_TRACE) {
  for (const k of Object.keys(env)) { const f = env[k]; env[k] = (...a) => { const r = f(...a); fs.writeSync(2, `${k}(${a.map(String).join(', ')}) -> ${String(r)}\n`); return r; }; }
}
// (STATIC_RUNTIME_WASM_PROFILE=1: how many times each function of the host was called, on the standard error when the program ends)
const calls = {};
if (process.env.STATIC_RUNTIME_WASM_PROFILE) {
  for (const k of Object.keys(env)) { const f = env[k]; calls[k] = 0; env[k] = (...a) => { calls[k]++; return f(...a); }; }
  process.onExit(() => { fs.writeSync(2, Object.entries(calls).filter(([, n]) => n > 0).sort((a, b) => b[1] - a[1]).map(([k, n]) => `${k}: ${n}`).join('\n') + '\n'); });
}
const imports = { env };
for (const i of WebAssembly.Module.imports(module)) {
  if (i.module !== 'env' || !(i.name in env)) throw new Error(`the program needs ${i.module}.${i.name}, which the host does not have`);
}
instance = new WebAssembly.Instance(module, imports);
memory = instance.exports.memory;
top = limit = BigInt(memory.buffer.byteLength);
errnoPtr = allocate(16n);                    // (the program's own data and stack are all of that: blocks come after it)

// the arguments of the command line, as `argc` and `argv` of a C program (each string, and the array of pointers, in memory)
const argv = allocate(BigInt(8 * (args.length + 1)));
if (argv === 0n) { fs.writeSync(2, 'Out of memory error\n'); return 1; }
args.forEach((a, i) => { const b = Buffer.from(a + '\0'); const p = allocate(BigInt(b.length)); u8().set(b, Number(p)); dv().setBigInt64(Number(argv) + 8 * i, p, true); });
let code;
try { code = instance.exports.main(args.length, argv); } catch (e) { if (e instanceof Exit) code = e.code; else { flushStdout(); throw e; } }
flushStdout();
return Number(code);
}

// Node harness: instantiate GuitarTuna's WebTuna.wasm with the real WebTuna.js import mapping.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const DOMAIN = "https://guitartuna.com/online-guitar-tuner";

let mem = null;
export const log = [];
export const calls = { consoleLog: [], consoleError: [], consoleWarn: [], thrown: [] };

// Exactly the mapping from the real /webtuna/WebTuna.js glue.
const IMPL = {
  a: "__cxa_throw",
  y: "__abort_js",
  j: "embind_bigint",
  l: "embind_bool",
  B: "embind_emval",
  i: "embind_float",
  e: "embind_function",
  c: "embind_integer",
  b: "embind_memory_view",
  k: "embind_std_string",
  d: "embind_std_wstring",
  m: "embind_void",
  o: "keepalive_clear",
  p: "setitimer",
  z: "tzset",
  f: "checkDomain",
  n: "console_error",
  C: "console_log",
  g: "console_warn",
  w: "date_now",
  h: "get_now",
  q: "resize_heap",
  u: "environ_get",
  v: "environ_sizes_get",
  x: "fd_close",
  s: "fd_read",
  t: "fd_seek",
  r: "fd_write",
  A: "proc_exit",
};

const u8 = () => new Uint8Array(mem.buffer);
const cstr = (p) => { const u = u8(); let e = p; while (u[e]) e++; return Buffer.from(u.subarray(p, e)).toString("utf8"); };

function make(letter) {
  const name = IMPL[letter];
  switch (name) {
    case "__cxa_throw":
      return (exn, msgPtr, dlt, dtor, dso) => {
        const msg = msgPtr ? cstr(msgPtr) : "";
        const e = new Error("C++ exception: " + msg);
        e.cppException = true; e.msg = msg;
        calls.thrown.push(msg);
        throw e;
      };
    case "__abort_js":
      return () => { throw new Error("abort()"); };
    case "checkDomain":
      return () => (DOMAIN.indexOf("guitartuna") !== -1 || DOMAIN.indexOf("yousician") !== -1 || DOMAIN.indexOf("localhost") !== -1) ? 1 : 0;
    case "console_error": { const parts = []; return (fd, iov, iovcnt, pnum) => { let n = 0; for (let i = 0; i < iovcnt; i++) { const ptr = new Uint32Array(mem.buffer)[iov >> 2]; const len = new Uint32Array(mem.buffer)[iov + 4 >> 2]; iov += 8; parts.push(Buffer.from(u8().subarray(ptr, ptr + len)).toString("utf8")); n += len; } new Uint32Array(mem.buffer)[pnum >> 2] = n; calls.consoleError.push(parts.join("")); return 0; }; }
    case "console_log": { const parts = []; return (fd, iov, iovcnt, pnum) => { let n = 0; for (let i = 0; i < iovcnt; i++) { const ptr = new Uint32Array(mem.buffer)[iov >> 2]; const len = new Uint32Array(mem.buffer)[iov + 4 >> 2]; iov += 8; parts.push(Buffer.from(u8().subarray(ptr, ptr + len)).toString("utf8")); n += len; } new Uint32Array(mem.buffer)[pnum >> 2] = n; calls.consoleLog.push(parts.join("")); return 0; }; }
    case "console_warn": return () => 0;
    case "date_now": return () => Date.now();
    case "get_now": return () => performance.now();
    case "resize_heap": {
      return (req) => {
        const cur = mem.buffer.byteLength;
        const need = Math.ceil((req + 65536) / 65536) * 65536;
        if (need > cur) { try { mem.grow((need - cur) / 65536); } catch (err) { return 0; } }
        return mem.buffer.byteLength;
      };
    }
    case "fd_read": return () => 52;
    case "fd_close": return () => 52;
    case "fd_seek": return () => 70;
    case "fd_write": return () => 0;
    case "environ_get": return () => 0;
    case "environ_sizes_get": return () => 0;
    case "proc_exit": return () => { throw new Error("proc_exit"); };
    default:
      if (name.startsWith("embind_")) {
        return (...a) => { log.push({ kind: name, args: a.map((x) => (typeof x === "bigint" ? x.toString() : x)) }); };
      }
      return () => 0;
  }
}

const bin = fs.readFileSync(path.join(HERE, "WebTuna.wasm"));
const mod = new WebAssembly.Module(bin);
const imports = { a: {} };
for (const l of Object.keys(IMPL)) imports.a[l] = make(l);

export const inst = new WebAssembly.Instance(mod, imports);
export const ex = inst.exports;
mem = ex.D;
ex.E(); // __wasm_call_ctors

export { mem, cstr };
export const I32 = () => new Int32Array(mem.buffer);
export const F32 = (a, n) => new Float32Array(mem.buffer, a, n);
export const F64 = (a, n) => new Float64Array(mem.buffer, a, n);
export const U8 = (a, n) => new Uint8Array(mem.buffer, a, n);

// public API discovered from the embind registration
export const analyseBuffer = ex.I.get(7);   // thunk; first arg = table index (8)
export const setTuningThunk = ex.I.get(9);
export const ANNOUNCE = "GuitarTuna WebTuna.wasm reverse-engineering harness";

export function analyse(buf, stringIdx, sampleRate) {
  const ptr = ex.H(buf.length * 4);
  F32(ptr, buf.length).set(buf);
  const r = analyseBuffer(8, ptr, buf.length, stringIdx, sampleRate);
  // f_haa returns a malloc'd block: [0]=byte length, [4..]=UTF-8 bytes
  const len = I32()[r >> 2];
  return JSON.parse(Buffer.from(U8(r + 4, len)).toString("utf8"));
}

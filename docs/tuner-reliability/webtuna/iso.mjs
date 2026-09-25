// Fresh instance per test so state never leaks between cases.
import fs from "node:fs";
const bin = fs.readFileSync("./WebTuna.wasm");
const mod = new WebAssembly.Module(bin);
const IMPL = { a:"__cxa_throw",y:"abort",j:"x",l:"x",B:"x",i:"x",e:"x",c:"x",b:"x",k:"x",d:"x",m:"x",o:"x",p:"x",z:"x",f:"checkDomain",n:"cerr",C:"clog",g:"x",w:"x",h:"x",q:"resize",u:"x",v:"x",x:"x",s:"x",t:"x",r:"x",A:"x" };
function fresh() {
  let mem;
  const imports = { a: {} };
  for (const l of Object.keys(IMPL)) imports.a[l] = (...args) => {
    switch (IMPL[l]) {
      case "checkDomain": return 1;
      case "resize": { const cur = mem.buffer.byteLength; const need = Math.ceil((args[0] + 65536) / 65536) * 65536; if (need > cur) { try { mem.grow((need - cur) / 65536); } catch { return 0; } } return mem.buffer.byteLength; }
      case "cerr": { const U32 = new Uint32Array(mem.buffer), U8 = new Uint8Array(mem.buffer); let s = ""; for (let i = 0; i < args[2]; i++) { const p = U32[args[1] >> 2], n = U32[args[1] + 4 >> 2]; args[1] += 8; s += Buffer.from(U8.subarray(p, p + n)).toString(); } console.error("[wasm]", s); return 0; }
      case "clog": return 0;
      default: return 0;
    }
  };
  const inst = new WebAssembly.Instance(mod, imports);
  const ex = inst.exports; mem = ex.D; ex.E();
  return { ex, mem, I: () => new Int32Array(mem.buffer), F: (a, n) => new Float32Array(mem.buffer, a, n) };
}
export function mk() {
  const { ex, mem, I, F } = fresh();
  const thunk = ex.I.get(7);
  const run = (buf, idx, sr) => {
    const p = ex.H(buf.length * 4);
    F(p, buf.length).set(buf);
    const r = thunk(8, p, buf.length, idx, sr);
    const len = I()[r >> 2];
    return JSON.parse(Buffer.from(new Uint8Array(mem.buffer, r + 4, len)).toString());
  };
  return { run, ex, mem, I, F };
}
export const NOTE = (m) => 440 * Math.pow(2, (m - 69) / 12);
export const H = [1, 0.5, 0.33, 0.25, 0.2, 0.16, 0.13];
export function tone(freq, sr = 44100, n = 4096, harm = H, noise = 0, dc = 0) {
  const o = new Float32Array(n);
  for (let i = 0; i < n; i++) { let s = 0; for (let k = 0; k < harm.length; k++) { const f = freq * (k + 1); if (f < sr / 2) s += harm[k] * Math.sin(2 * Math.PI * f * i / sr); } o[i] = s * 0.2 + dc; }
  if (noise) for (let i = 0; i < n; i++) o[i] += (Math.random() * 2 - 1) * noise;
  return o;
}

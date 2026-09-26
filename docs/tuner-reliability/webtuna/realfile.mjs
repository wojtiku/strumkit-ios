// Run a real recording through the WebTuna oracle and report every call.
// Usage: node realfile.mjs <wav> [stringIdx]
import { mk } from "./iso.mjs";
import { readFileSync } from "node:fs";

const path = process.argv[2];
const IDX = Number(process.argv[3] ?? -1);
const CHUNK = 4096;

function decodeWav(buf) {
  if (buf.toString("ascii", 0, 4) !== "RIFF") throw new Error("not RIFF");
  let off = 12, fmt = null, data = null;
  while (off + 8 <= buf.length) {
    const id = buf.toString("ascii", off, off + 4);
    const size = buf.readUInt32LE(off + 4);
    if (id === "fmt ") {
      fmt = { format: buf.readUInt16LE(off + 8), channels: buf.readUInt16LE(off + 10),
              rate: buf.readUInt32LE(off + 12), bits: buf.readUInt16LE(off + 22) };
    } else if (id === "data") {
      data = buf.subarray(off + 8, off + 8 + size);
    }
    off += 8 + size + (size & 1);
  }
  const bytes = fmt.bits / 8, frames = Math.floor(data.length / (bytes * fmt.channels));
  const out = new Float32Array(frames);
  for (let i = 0; i < frames; i++) {
    let acc = 0;
    for (let c = 0; c < fmt.channels; c++) {
      const p = (i * fmt.channels + c) * bytes;
      acc += fmt.bits === 16 ? data.readInt16LE(p) / 32768
           : fmt.bits === 32 ? data.readFloatLE(p)
           : data.readUInt8(p) / 128 - 1;
    }
    out[i] = acc / fmt.channels;
  }
  return { samples: out, rate: fmt.rate };
}

const { samples, rate } = decodeWav(readFileSync(path));
console.log(`${path}: ${samples.length} frames @ ${rate} Hz = ${(samples.length/rate).toFixed(2)}s, stringIdx=${IDX}`);

const { run } = mk();                       // fresh instance: stateful singleton
const nChunks = Math.floor(samples.length / CHUNK);
const STRING = ["E4","B3","G3","D3","A2","E2"];

let heard = 0, switches = 0, lastStr = null, inTune = 0;
const rows = [];
for (let c = 0; c < nChunks; c++) {
  const o = run(samples.subarray(c * CHUNK, (c + 1) * CHUNK), IDX, rate);
  const t = (c + 1) * CHUNK / rate;
  if (o.CanHearANote && o.MeasuredPitchHz > 0) {
    heard++;
    if (o.InTuneRatio > 0.9) inTune++;
    const s = o.CurrentString;
    if (s !== lastStr && s >= 0) { if (lastStr !== null) switches++; lastStr = s; }
  }
  rows.push({ t, hz: o.MeasuredPitchHz, str: o.CurrentString, can: o.CanHearANote,
              ratio: o.InTuneRatio, pw: o.PossibleWrongStringId, rms: o.MicRms });
}

console.log(`\ncalls=${nChunks}  heard=${heard} (${(100*heard/nChunks).toFixed(0)}%)  ` +
            `inTune(ratio>0.9)=${inTune}  string switches=${switches}`);
console.log(`peak MicRms=${Math.max(...rows.map(r=>r.rms)).toFixed(4)}`);

// Group contiguous heard calls into segments and quantify steadiness.
const segs = [];
let cur = null;
for (const r of rows) {
  if (r.can && r.hz > 0) {
    if (!cur || r.t - cur.last > 0.4) { cur = { t0: r.t, hz: [], str: r.str, last: r.t }; segs.push(cur); }
    cur.hz.push(r.hz); cur.last = r.t;
    if (cur.str !== r.str) cur.strMixed = true;
  }
}
console.log("\n  seg    t0(s)  dur(s)  str  n   Hz mean     sd     cents spread (p5-p95)");
const NOTE = ["E4","B3","G3","D3","A2","E2"];
const REF = [329.63,246.94,196.00,146.83,110.0,82.41];
for (const g of segs) {
  const n = g.hz.length, mean = g.hz.reduce((a,b)=>a+b,0)/n;
  const sd = Math.sqrt(g.hz.reduce((a,b)=>a+(b-mean)**2,0)/n);
  const c = g.hz.map(h => 1200*Math.log2(h/REF[g.str] ?? mean)).sort((a,b)=>a-b);
  const p = q => c[Math.min(c.length-1, Math.max(0, Math.round(q*(c.length-1))))];
  console.log(`  ${String(segs.indexOf(g)).padStart(3)} ${g.t0.toFixed(3).padStart(7)} ` +
    `${((g.last-g.t0)+0.085).toFixed(2).padStart(6)} ${String(NOTE[g.str] ?? "?").padStart(4)}` +
    `${String(n).padStart(4)} ${mean.toFixed(2).padStart(8)} ${sd.toFixed(3).padStart(7)}` +
    `   ${(p(0.95)-p(0.05)).toFixed(1).padStart(6)}${g.strMixed ? "  MIXED-STR" : ""}`);
}
console.log(`\n  ${segs.length} segments, ${heard} heard calls, ${switches} string switches`);

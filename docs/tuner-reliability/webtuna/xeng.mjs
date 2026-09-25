// docs/tuner-reliability/webtuna/xeng.mjs
// Runs the coverage-matrix cells through the WebTuna oracle and emits
// XWEB|... lines for the same cell labels the Swift emitter prints.
// The wasm is Yousician's IP and is NOT committed; fetch it untracked:
//
//   curl -o WebTuna.wasm https://guitartuna.com/webtuna/WebTuna.wasm
//   node xeng.mjs > xweb-trace.txt
//
// Run it from THIS directory: `iso.mjs` reads `./WebTuna.wasm` relative to the
// process cwd. `xcells.json` is read module-relative, so it does not care.
//
// -----------------------------------------------------------------------------
// Polyphony: `cell.extraFrequencies` is synthesised, so the four `poly-` cells
// really do carry a second voice on both sides. `extraStrings` is the cell's
// record of which strings were declared; `extraFrequencies` is what the audio
// generator reads. They are the same list, and `polyCellsArePolyphonic` in
// `StrumKitTests/CoverageMatrixTests.swift` is what keeps them from drifting —
// before that test existed they diverged silently and the whole matrix rendered
// as single notes.
// -----------------------------------------------------------------------------

import { mk } from "./iso.mjs";
import { readFileSync } from "node:fs";

const RATE = 44100;
const CHUNK = 4096;            // WebTuna's hard-coded input size
const CENTS_TOLERANCE = 50;    // mirrors CrossEngineComparisonTests.centsTolerance
// Mirrors CoverageMatrix.extraVoiceWeight. MUST match: if the two sides weight a
// second voice differently, every poly- cell's `sig=` checksum diverges and
// xcompare.py refuses to score.
const EXTRA_VOICE_WEIGHT = 0.7;

// WebTuna's compiled-in tuning is a six-string guitar:
//   [329.6276, 246.9417, 195.9977, 146.8324, 110.0, 82.4069]  // idx 0 = highest
// so there is no ukulele. `xcells.json` therefore carries a per-cell `idx` of
// -1 (auto, within the guitar tuning) or -2 (chromatic) for ukulele cells; it
// is decided on the Swift side, from the cell's own instrument, and is not
// re-derived here.

// Emitted by StrumKitTests/CrossEngineComparisonTests.swift. Kept in sync by
// hand in exactly one direction only: the Swift side writes this file, this
// file reads it. A cell one side knows about and the other does not is
// therefore a visible missing row, not a silent disappearance.
const cells = JSON.parse(readFileSync(new URL("./xcells.json", import.meta.url), "utf8"));

// Mirrors CoverageMatrix.Case / CoverageMatrix.signal. Read the Swift original
// before changing any line here: if the two generators drift, the comparison is
// meaningless, and the only thing standing between that and a confident wrong
// answer is the `sig=` checksum on every SUMMARY line.
function buildSignal(cell, rate = RATE, seconds = 3.0) {
  // Swift: Int((rate * seconds).rounded()). `.rounded()` breaks ties away from
  // zero, `Math.round` toward +Infinity; they differ only on an exact .5, and
  // RATE * 3.0 is exact.
  const n = Math.round(rate * seconds);
  const out = new Float32Array(n);
  const weights = [cell.h1, cell.h2, cell.h3, cell.h4];
  let peak = 0;
  for (let i = 0; i < n; i++) {
    const t = i / rate;
    let sum = 0;
    for (let k = 0; k < 4; k++) {
      const w = weights[k];
      if (w === 0) continue;                         // Swift: `where w != 0`
      const nd = k + 1;
      const fn = nd * cell.truthHz * Math.sqrt(1 + cell.inharmonicity * nd * nd);
      if (fn >= rate / 2) continue;                  // Swift: `guard fn < rate/2`
      sum += w * Math.sin(2 * Math.PI * fn * t + 0.4 * k);
    }
    // Additional voices (spec §6's polyphony axis), rendered as plain sines at
    // the primary's amplitude scale. Inside the same envelope, so a second voice
    // decays with the first.
    for (const f of cell.extraFrequencies || []) {
      if (f < rate / 2) sum += EXTRA_VOICE_WEIGHT * Math.sin(2 * Math.PI * f * t);
    }
    const attack = Math.min(1, t / Math.max(cell.attackSeconds, 1e-6));
    const envelope = attack * Math.exp(-t / cell.decayTau);
    const v = cell.amplitude * envelope * sum;
    out[i] = v;
    peak = Math.max(peak, Math.abs(v));
  }
  if (cell.snrDB === "clean" || peak === 0) return out;

  const scale = cell.amplitude / peak;
  let sumSq = 0;
  for (const v of out) sumSq += v * v;
  const signalPower = sumSq / out.length;
  const noiseAmplitude = Math.sqrt(signalPower) * Math.pow(10, -cell.snrDB / 20) * Math.sqrt(3);

  // Swift uses `&*` (wrapping) and a UInt64 seed; the state is below 2^31 from
  // the first step and each product is below 2^47, so plain double arithmetic is
  // exact here and cannot diverge.
  let lcg = cell.seed === 0 ? 1 : cell.seed;
  for (let i = 0; i < n; i++) {
    lcg = (lcg * 48271) % 2147483647;
    out[i] += noiseAmplitude * ((lcg / 2147483647) * 2 - 1);
  }
  // float32 store on every write, exactly as `Float(...)` does on the Swift side.
  for (let i = 0; i < n; i++) out[i] *= scale;
  return out;
}

// FNV-1a, 32-bit, over the raw sample bytes. Identical function, identical
// bytes, identical result — see fnv1a32(_:) in the Swift emitter. If these ever
// disagree, the two sides fed the engines different audio and every number
// downstream is void.
function fnv1a32(samples) {
  const bytes = new Uint8Array(samples.buffer, samples.byteOffset, samples.byteLength);
  let h = 2166136261;
  for (let i = 0; i < bytes.length; i++) {
    h = (h ^ bytes[i]) >>> 0;
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h >>> 0;
}

const hex8 = (v) => v.toString(16).padStart(8, "0");
const f5 = (v) => (v === null || v === undefined ? (-1).toFixed(5) : v.toFixed(5));

for (const cell of cells) {
  const { run } = mk();          // fresh instance: the engine is a stateful singleton
  const audio = buildSignal(cell);
  const sig = fnv1a32(audio);
  let firstHeard = null, lastHeard = null, chunks = 0;

  // Feed the whole signal. WebTuna's ABI is a fixed 4096-sample call, so at
  // 3.0 s / 44.1 kHz this is 32 calls covering 2.97 s; the 1228-sample
  // remainder is the only part it cannot accept. Truncating the loop instead
  // would matter: its first two calls ALWAYS return CanHearANote == false
  // (three frames before it will name a note), so a short loop would report
  // "did not hear" for cells it never gave a chance.
  for (let s = 0; s + CHUNK <= audio.length; s += CHUNK) {
    const o = run(audio.subarray(s, s + CHUNK), cell.idx, RATE);
    chunks++;
    const t = (s + CHUNK) / RATE;
    const hz = typeof o.MeasuredPitchHz === "number" ? o.MeasuredPitchHz : 0;
    if (o.CanHearANote && hz > 0) {
      const cents = 1200 * Math.log2(hz / cell.noteHz);
      if (Math.abs(cents) <= CENTS_TOLERANCE) {
        if (firstHeard === null) firstHeard = t;
        lastHeard = t;
      }
    }
    const ratio = typeof o.InTuneRatio === "number" ? o.InTuneRatio : 0;
    const rms = typeof o.MicRms === "number" ? o.MicRms : 0;
    console.log(`XWEB|${cell.label}|t=${t.toFixed(5)}|hz=${hz.toFixed(4)}`
      + `|cents=${hz > 0 ? (1200 * Math.log2(hz / cell.noteHz)).toFixed(3) : "nan"}`
      + `|ratio=${ratio.toFixed(3)}|str=${o.CurrentString}`
      + `|rms=${rms.toFixed(6)}|pw=${o.PossibleWrongStringId}|calls=${chunks}`);
  }

  console.log(`XWEB-SUMMARY|${cell.label}|truth=${cell.noteHz}`
    + `|first=${f5(firstHeard)}|last=${f5(lastHeard)}`
    + `|chunks=${chunks}`
    + `|extraStrings=${(cell.extraStrings || []).length}`
    + `|sig=${hex8(sig)}`);
}

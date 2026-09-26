// swift-reference/tools/oracle-trace.mjs
//
// Runs the REAL WebTuna.wasm over the coverage matrix and records, per call, the
// nine fields `analyseBuffer` returns. That JSON is `Fixtures/oracle-trace.json`,
// the fixture the Swift conformance tests score against.
//
// The wasm is Yousician's intellectual property and is never committed. Fetch it
// first, and verify the SHA-256 — the recorded one is in the trace's `wasmSHA256`
// field and is the same value as in WEBTUNA.md §0:
//
//   cd docs/tuner-reliability/webtuna
//   curl -o WebTuna.wasm https://guitartuna.com/webtuna/WebTuna.wasm
//   shasum -a 256 WebTuna.wasm
//   node swift-reference/tools/oracle-trace.mjs > swift-reference/Fixtures/oracle-trace.json
//
// Run it from the webtuna/ directory: iso.mjs reads ./WebTuna.wasm relative to the
// process cwd. The signal generator is imported from xeng.mjs's source of truth
// (xcells.json) and reimplemented identically here, so the `sig` field is a real
// parity check rather than a copy of a number.
import { mk } from "../../iso.mjs";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SWIFT_REFERENCE = path.resolve(HERE, "..");

const RATE = 44100;
const CHUNK = 4096;
const EXTRA_VOICE_WEIGHT = 0.7; // must match CoverageMatrix.extraVoiceWeight
const EXPECTED_SHA = "14ec8582a5cd1becfc8597fbc8bec75d2361f57522046ffdb0fbafc9394508bd";

const cells = JSON.parse(readFileSync(path.resolve(SWIFT_REFERENCE, "Fixtures/xcells.json"), "utf8"));

// --- signal generation -------------------------------------------------------
// Byte-for-byte the same sequence of operations as
// CoverageMatrix.signal(for:) in Swift. Every assignment below is a float32
// store in JS and a Float(...) store in Swift; that is what makes the FNV-1a
// checksums comparable.
function buildSignal(cell, rate = RATE, seconds = 3.0) {
  const n = Math.round(rate * seconds);
  const out = new Float32Array(n);
  const weights = [cell.h1, cell.h2, cell.h3, cell.h4];
  let peak = 0;
  for (let i = 0; i < n; i++) {
    const t = i / rate;
    let sum = 0;
    for (let k = 0; k < 4; k++) {
      const w = weights[k];
      if (w === 0) continue;
      const nd = k + 1;
      const fn = nd * cell.truthHz * Math.sqrt(1 + cell.inharmonicity * nd * nd);
      if (fn >= rate / 2) continue;
      sum += w * Math.sin(2 * Math.PI * fn * t + 0.4 * k);
    }
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

  let lcg = cell.seed === 0 ? 1 : cell.seed;
  for (let i = 0; i < n; i++) {
    lcg = (lcg * 48271) % 2147483647;
    out[i] += noiseAmplitude * ((lcg / 2147483647) * 2 - 1);
  }
  for (let i = 0; i < n; i++) out[i] *= scale;
  return out;
}

function fnv1a32(samples) {
  const bytes = new Uint8Array(samples.buffer, samples.byteOffset, samples.byteLength);
  let h = 2166136261;
  for (let i = 0; i < bytes.length; i++) {
    h = (h ^ bytes[i]) >>> 0;
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h >>> 0;
}

// --- drive the oracle --------------------------------------------------------
const sha = createHash("sha256").update(readFileSync("./WebTuna.wasm")).digest("hex");
if (sha !== EXPECTED_SHA) {
  console.error(`FATAL: WebTuna.wasm SHA-256 is ${sha}, expected ${EXPECTED_SHA}`);
  process.exit(2);
}

const outCells = [];
for (const cell of cells) {
  const { run } = mk();               // fresh instance: the engine is a stateful singleton
  const audio = buildSignal(cell);
  const sig = fnv1a32(audio).toString(16).padStart(8, "0");
  const frames = [];
  let call = 0;
  for (let s = 0; s + CHUNK <= audio.length; s += CHUNK) {
    const o = run(audio.subarray(s, s + CHUNK), cell.idx, RATE);
    frames.push({
      call,
      canHearANote: o.CanHearANote,
      currentString: o.CurrentString,
      inTuneRatio: o.InTuneRatio,
      measuredPitchHz: o.MeasuredPitchHz,
      measuredPitchMidi: o.MeasuredPitchMidi,
      micRms: o.MicRms,
      possibleWrongStringId: o.PossibleWrongStringId,
      tuningErrorCents: o.TuningErrorCents,
      truthHz: cell.noteHz,
    });
    call++;
  }
  outCells.push({
    label: cell.label,
    index: cell.idx,
    truthHz: cell.noteHz,
    calls: call,
    sig,
    frames,
  });
  process.stderr.write(`${cell.label} ${call} calls sig=${sig}\n`);
}

process.stdout.write(JSON.stringify({
  sampleRate: RATE,
  wasmSHA256: sha,
  cells: outCells,
}, null, 1) + "\n");

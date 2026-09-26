// swift-reference/tools/probe-fields.mjs
//
// READ-ONLY oracle probe. Run from the webtuna/ directory so iso.mjs finds
// ./WebTuna.wasm in the cwd:
//
//   cd docs/tuner-reliability/webtuna
//   node swift-reference/tools/probe-fields.mjs
//
// Purpose: identify the engine's `g` struct fields (offsets 8..64) by watching
// them change against the JSON the engine reports. WEBTUNA.md names g[15],
// g[28], g[32], g[33], g[34], g[37], g[47], g[48] but not what several of them
// hold, and the decompile is ambiguous about whether the Hz/cents outputs are
// floor()ed or rint()ed. This settles both by measurement.
import { mk, tone, NOTE, H } from "../../iso.mjs";

const { run, I, F, mem } = mk();
const I32 = I;
// The engine singleton is allocated on the first analyseBuffer call, so 36140
// reads 0 until then. Take the address after one throwaway call.
run(tone(NOTE(40)), -1, 44100);
const G = I32()[36140 >> 2];

// Fields the decompile (func708) actually reads or writes.
const FIELDS = [9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 21, 22, 25, 27, 28,
  30, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 44, 45, 47, 48, 49, 52, 64,
  68, 69, 70, 71, 72, 73, 104, 116, 124, 140];

const snap = () => {
  const o = {};
  for (const f of FIELDS) {
    const iv = I32()[(G >> 2) + f];
    const fv = F(G + f * 4, 1)[0];
    o[f] = { i: iv, f: fv };
  }
  return o;
};
const fmt = (v) => (Number.isFinite(v.f) && Math.abs(v.f) >= 1e-4 && Math.abs(v.f) < 1e7
  ? v.f.toFixed(6).padStart(14) + "  " : "".padStart(14) + "  ") + String(v.i).padStart(12);

const midiHz = NOTE(40); // E2 = 82.4069
console.log("engine g =", G, " tone =", midiHz.toFixed(4), "Hz (E2), 7 harmonics, 0.2 gain\n");
let prev = snap();
console.log("call | " + FIELDS.map((f) => String(f).padStart(26)).join(" |"));
for (let call = 0; call < 22; call++) {
  const o = run(tone(midiHz), -1, 44100);
  const s = snap();
  const changed = FIELDS.filter((f) => s[f].i !== prev[f].i || s[f].f !== prev[f].f);
  console.log(`--- call ${call}  hz=${o.MeasuredPitchHz} cents=${o.TuningErrorCents} midi=${o.MeasuredPitchMidi} rms=${o.MicRms} ratio=${o.InTuneRatio} str=${o.CurrentString} hear=${o.CanHearANote} pw=${o.PossibleWrongStringId}`);
  for (const f of changed) console.log("      g[" + String(f).padStart(3) + "] " + fmt(s[f]));
  prev = s;
}
console.log("\nJSON keys actually emitted:", Object.keys(run(tone(midiHz), -1, 44100)).join(", "));

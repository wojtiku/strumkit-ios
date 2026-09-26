// swift-reference/tools/probe-intermediates.mjs
//
// READ-ONLY oracle probe: dump the engine's own intermediate arrays so the Swift
// port's stages 1-5 can be checked value-by-value instead of only end-to-end.
//
// The 56 band values and the compressed-magnitude array are never reported in the
// JSON, so there is no other way to confirm that the Swift filterbank really is
// the same filterbank. The arrays are identified by content, not by struct
// offset: `func708` writes the band values at `m[18]`, the compressed magnitudes
// at `m[30]` and the residual at `m[24]`, but the decompiler's field indices do
// not survive into the real layout, so the addresses were found by scanning the
// `Ooura_FFT` object for 56-float arrays and matching the expected magnitudes.
//
// Run from the webtuna/ directory:
//   cd docs/tuner-reliability/webtuna
//   node swift-reference/tools/probe-intermediates.mjs > swift-reference/Fixtures/intermediates-e2.json
import { mk, tone, NOTE, H } from "../../iso.mjs";

const { run, I, F } = mk();
const SR = 44100;
const CALLS = 20;

const caseDef = (label, freq, idx, harm) => ({ label, freq, idx, harm });
const cases = [
  caseDef("e2-7harm", NOTE(40), -1, H),          // E2, the 7-harmonic reference tone
  caseDef("e4-7harm", NOTE(64), -1, H),          // E4, the other end of the guitar
  caseDef("a2-3harm", NOTE(45), -1, [1, 0.5, 0.33, 0, 0, 0, 0]),
  caseDef("e2-pure", NOTE(40), -1, [1, 0, 0, 0, 0, 0, 0]),
  caseDef("d3-chromatic", NOTE(50), -2, H),
];

const out = { sampleRate: SR, cases: [] };

for (const c of cases) {
  // Fresh instance per case: the engine is a process-wide singleton with no reset
  // (WEBTUNA.md §5.10), so state would otherwise leak.
  const { run: r, I: I2, F: F2 } = mk();
  let last = null;
  for (let k = 0; k < CALLS; k++) last = r(tone(c.freq, SR, 4096, c.harm), c.idx, SR);

  const G = I2()[36140 >> 2];
  const K = I2()[(G >> 2)];
  const J = I2()[(K >> 2) + 25];
  const spectrum = Array.from(F2(I2()[(K >> 2) + 31], 1136));

  // The 56-float arrays. `func708` writes the band values into one slice and the
  // compressed magnitudes into another; in the real layout (as opposed to the
  // decompiler's field indices) they are at +27 and +30 of the `Ooura_FFT`
  // object. The identification is *verified* below against the transform
  // relation, so a layout change would be caught rather than silently trusted.
  const rawBands = Array.from(F2(I2()[(J >> 2) + 27], 56));
  const compressed = Array.from(F2(I2()[(J >> 2) + 30], 56));
  let sumB = 0;
  for (const v of rawBands) sumB += v;
  const floorValue = sumB / 56 * 1e-4;
  const relErr = Math.max(...rawBands.map((m, k) => {
    const a = Math.cbrt(Math.sqrt((Math.max(m, floorValue) * 2) / 4095));
    return Math.abs(a - compressed[k]) / Math.max(1e-12, Math.abs(compressed[k]));
  }));
  if (!(relErr < 1e-4)) {
    throw new Error(`${c.label}: band/compressed identification failed (relErr=${relErr})`);
  }
  const bands = rawBands;
  // The residual is defined by the two arrays, and is dumped so the Swift port's
  // `i[k] = m[k]/a[k]` can be checked against the value implied by the engine.
  const residual = bands.map((m, k) => m / compressed[k]);

  let sumSq = 0;
  for (const v of spectrum) sumSq += v * v;
  out.cases.push({
    label: c.label,
    freq: c.freq,
    idx: c.idx,
    calls: CALLS,
    spectrum,
    spectrumRMS: Math.sqrt(sumSq / spectrum.length),
    bands,
    compressed,
    residual,
    output: last,
  });
  console.error(`${c.label}: relErr=${relErr.toExponential(2)}`
    + ` band[8]=${bands[8].toExponential(6)} comp[8]=${compressed[8].toExponential(6)}`
    + ` specRMS=${out.cases.at(-1).spectrumRMS.toExponential(8)}`
    + ` hz=${last.MeasuredPitchHz} cents=${last.TuningErrorCents} rms=${last.MicRms}`);
}

process.stdout.write(JSON.stringify(out, null, 1) + "\n");

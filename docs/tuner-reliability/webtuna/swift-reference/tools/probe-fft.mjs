// swift-reference/tools/probe-fft.mjs
//
// READ-ONLY oracle probe: how does the engine scale its spectrum?
//
// The filterbank and the salience are both scale-invariant, so the absolute
// scale of the 1136-float spectrum only shows up in MicRms, which is
// `128 * sqrt(sumSquares/1136)`. WEBTUNA.md §3.8 measures the constant as
// `MicRms / inputRMS = 0.239` but never says what the spectrum is scaled by.
// This measures it directly, on a pure sine whose FFT peak is analytically known.
import { mk, NOTE, H } from "../../iso.mjs";

const { run, I, F, mem } = mk();
const I32 = I;
run(new Float32Array(4096), -1, 44100);      // force the singleton into existence
const G = I32()[36140 >> 2];
const K = I32()[(G >> 2)];                    // the inner per-frame object
const J = I32()[(K >> 2) + 25];               // the Ooura_FFT object (k[25])

console.log("engine g =", G, " k =", K, " fftObj =", J);
const JI = (i) => I32()[(J >> 2) + i];
const JF = (i) => F(J + i * 4, 1)[0];
console.log(`J: fftSize=${JI(4)} complexSize=${JI(5)} candLo=${JI(6)} candCount=${JI(7)}`
  + ` bandLo=${JI(11)} bandHi=${JI(10)} sr=${JF(3)} msThreshold=${JF(0)}`);

// k[31] is where the 1136-float spectrum is copied to each frame.
const SPEC = I32()[(K >> 2) + 31];
console.log("k[31] spectrum copy =", SPEC);

const SR = 44100;
function sineAt(freq, amp, n = 4096) {
  const o = new Float32Array(n);
  for (let i = 0; i < n; i++) o[i] = amp * Math.sin(2 * Math.PI * freq * i / SR);
  return o;
}

// Frequencies placed *exactly* on an FFT bin, so the peak bin is analytically
// A/2 * sum(window) and the only unknown left is the engine's own scale factor.
const onBin = (b) => (b * SR) / 8192;
for (const b of [8, 15, 20, 40, 82, 200]) {
  const freq = onBin(b);
  const amp = 1.0;
  const { run: r2, I: I3, F: F3 } = mk();
  for (let k = 0; k < 6; k++) r2(sineAt(freq, amp), -1, SR);
  const G3 = I3()[36140 >> 2];
  const KK = I3()[(G3 >> 2)];
  const spec = I3()[(KK >> 2) + 31];
  const s = Array.from(F3(spec, 1136));
  const peak = Math.max(...s);
  let sumSq = 0; for (const v of s) sumSq += v * v;
  const rms = Math.sqrt(sumSq / 1136);

  // sum(window) for 0.54 - 0.46*cos(2*pi*n/4095) over n = 0..4095.
  let wsum = 0;
  for (let n = 0; n < 4096; n++) wsum += 0.54 - 0.46 * Math.cos((2 * Math.PI * n) / 4095);
  const analytic = (amp / 2) * wsum;
  // The engine also has a fallback path where the first bin is 0; guard against a
  // degenerate reading rather than dividing by it.
  if (!(peak > 0)) { console.log(`bin ${b}: silent`); continue; }
  console.log(`bin=${String(b).padStart(3)} f=${freq.toFixed(3)}Hz peak=${peak.toExponential(8)}`
    + `  peak/analytic=${(peak / analytic).toExponential(8)}`
    + `  specRMS=${rms.toExponential(8)}  128*specRMS=${(128 * rms).toFixed(8)}`);
}

// Is YIN the right primary estimator for a GUITAR TUNER?
//
// YIN is state of the art for the frequency of a periodic signal. A guitar tuner
// is a different problem: the output space is 6 known frequencies, the input is a
// plucked string whose fundamental is often weaker than its 2nd harmonic, and the
// SNR decays over the note's life.
//
// This sweeps fundamental strength x SNR and reports, for each cell:
//   yinLag     - did the CMNDF produce a trough at all?
//   yinAccept  - did it survive STRUMKIT's own gates (CMNDF threshold + the
//                0.004 fundamental-energy ratio that PitchDetector applies)?
//   webtuna    - did WebTuna's salience name a note?
//
// YIN runs at StrumKit's own analysis rate (16 kHz, 1536-sample window) and with
// StrumKit's own parameters, so the "accepted" column is what StrumKit actually does.

import { mk } from "./iso.mjs";

const RATE_YIN = 16000;
const WIN = 1536;
const MIN_LAG = Math.max(2, Math.floor(RATE_YIN / 1100));   // 14
const MAX_LAG = Math.min(WIN >> 1, Math.ceil(RATE_YIN / 50)); // 320
const SPAN = WIN - MAX_LAG;
const THRESHOLD = 0.15;
const FUNDAMENTAL_MIN_ENERGY_RATIO = 0.004;   // PitchDetector.fundamentalMinEnergyRatio
const HIGH_NOTE_RATIO = 0.002;                 // used when f > 300 Hz

// ---- reference YIN, matching StrumKit/PitchDetector -------------------------
function yin(samples) {
  const diff = new Float64Array(MAX_LAG + 1);
  for (let tau = 1; tau <= MAX_LAG; tau++) {
    let sum = 0;
    for (let i = 0; i < SPAN; i++) {
      const d = samples[i] - samples[i + tau];
      sum += d * d;
    }
    diff[tau] = sum;
  }
  // CMNDF
  const cmnd = new Float64Array(MAX_LAG + 1);
  cmnd[0] = 1;
  let running = 0;
  for (let tau = 1; tau <= MAX_LAG; tau++) {
    running += diff[tau];
    cmnd[tau] = running > 0 ? (diff[tau] * tau) / running : 1;
  }
  // first trough below threshold
  let tauEst = -1;
  for (let tau = MIN_LAG; tau <= MAX_LAG; tau++) {
    if (cmnd[tau] < THRESHOLD) {
      while (tau + 1 <= MAX_LAG && cmnd[tau + 1] < cmnd[tau]) tau++;
      tauEst = tau;
      break;
    }
  }
  if (tauEst < 0) {
    // global minimum, if it is a plausible trough
    let best = MIN_LAG;
    for (let tau = MIN_LAG + 1; tau <= MAX_LAG; tau++) if (cmnd[tau] < cmnd[best]) best = tau;
    if (cmnd[best] > 0.35) return { ok: false, reason: "no-trough", cmnd: cmnd[best] };
    tauEst = best;
  }
  // parabolic refinement on the DIFFERENCE function (as StrumKit does)
  let betterTau = tauEst;
  if (tauEst > 0 && tauEst < MAX_LAG) {
    const s0 = diff[tauEst - 1], s1 = diff[tauEst], s2 = diff[tauEst + 1];
    const denom = 2 * (2 * s1 - s2 - s0);
    if (Math.abs(denom) > 1e-15) {
      const delta = (s2 - s0) / denom;
      if (Math.abs(delta) < 1) betterTau = tauEst + delta;
    }
  }
  const f0 = RATE_YIN / betterTau;

  // StrumKit's fundamental-energy gate: normalised Hann projection power at f0
  // divided by mean square. A pitch "exists" only if the fundamental carries
  // enough of the energy.
  const angStep = (2 * Math.PI * f0) / RATE_YIN;
  let re = 0, im = 0, w = 0;
  for (let i = 0; i < WIN; i++) {
    const win = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (WIN - 1));
    const a = angStep * i;
    re += samples[i] * win * Math.cos(a);
    im += samples[i] * win * Math.sin(a);
    w += win;
  }
  const projPow = (re * re + im * im) / (w * w) / 2;
  let ms = 0;
  for (let i = 0; i < WIN; i++) ms += samples[i] * samples[i];
  ms /= WIN;
  const ratio = ms > 0 ? projPow / ms : 0;
  const need = f0 > 300 ? HIGH_NOTE_RATIO : FUNDAMENTAL_MIN_ENERGY_RATIO;
  return {
    ok: true, f0, ratio, need,
    accepted: ratio >= need,
    cmnd: cmnd[tauEst],
  };
}

// ---- signal generation ------------------------------------------------------
let seed = 12345;
function rand() { seed = (seed * 48271) % 2147483647; return seed / 2147483647; }

function gen(rate, f0, h1w, h2w, h3w, h4w, snrDb, n) {
  const out = new Float64Array(n);
  const decay = Math.exp(-((n / rate) * 0.5) / 1.8);
  for (let i = 0; i < n; i++) {
    const t = i / rate;
    const a = 2 * Math.PI * f0 * t;
    out[i] = 0.2 * decay * (h1w * Math.sin(a) + h2w * Math.sin(2 * a + 0.4)
      + h3w * Math.sin(3 * a + 0.8) + h4w * Math.sin(4 * a + 1.2));
  }
  if (isFinite(snrDb)) {
    let ms = 0; for (const s of out) ms += s * s; ms /= n;
    const amp = Math.sqrt(ms) * Math.pow(10, -snrDb / 20) * Math.sqrt(3);
    for (let i = 0; i < n; i++) out[i] += amp * (rand() * 2 - 1);
  }
  return out;
}

// ---- sweep ------------------------------------------------------------------
const F0 = 82.4069;                      // low E, the hardest string
const H1 = [1.0, 0.3, 0.1, 0.03, 0.01, 0.004];
const SNR = [Infinity, 20, 12, 6, 0];
const TRIALS = 12;

console.log(`Low E ${F0} Hz. ${TRIALS} trials/cell. YIN at ${RATE_YIN} Hz x ${WIN} samples.`);
console.log("'accept' = survived StrumKit's own CMNDF + 0.004 fundamental-energy gates.\n");

const hdr = ["h1", ...SNR.map((s) => (isFinite(s) ? `${s}dB` : "clean"))];
console.log(["YIN lag found  ", ...hdr].map((c) => String(c).padStart(8)).join(""));
console.log(["YIN ACCEPTED   ", ...hdr].map(() => "".padStart(8)).join(""));
console.log(["WebTuna heard  ", ...hdr].map(() => "".padStart(8)).join(""));
console.log(["fund energy %  ", ...hdr].map(() => "".padStart(8)).join(""));
console.log(["f0 CORRECT     ", ...hdr].map(() => "".padStart(8)).join(""));
console.log("-".repeat(8 * (hdr.length + 1)));

for (const h1w of H1) {
  const rows = [[], [], [], [], []];
  for (const snr of SNR) {
    let lagFound = 0, accepted = 0, heard = 0, ratioSum = 0, ratioN = 0, correct = 0, octErr = 0;
    for (let t = 0; t < TRIALS; t++) {
      // --- YIN at 16 kHz, steady mid-decay window ---
      const sig = gen(RATE_YIN, F0, h1w, 0.30, 0.15, 0.10, snr, WIN);
      const r = yin(sig);
      if (r.ok) {
        lagFound++; ratioSum += r.ratio; ratioN++;
        if (r.accepted) accepted++;
        const c = 1200 * Math.log2(r.f0 / F0);
        if (Math.abs(c) < 50) correct++;
        else if (Math.abs(Math.abs(c) - 1200) < 50) octErr++;
      }

      // --- WebTuna at 44.1 kHz, its native cadence ---
      const { run } = mk();
      const CH = 4096, NCH = 6;
      const big = gen(44100, F0, h1w, 0.30, 0.15, 0.10, snr, CH * NCH);
      const f32 = new Float32Array(big);
      let any = false;
      for (let c = 0; c < NCH; c++) {
        const o = run(f32.subarray(c * CH, (c + 1) * CH), -1, 44100);
        if (o.CanHearANote && o.MeasuredPitchHz > 0) any = true;
      }
      if (any) heard++;
    }
    rows[0].push(`${lagFound}/${TRIALS}`);
    rows[1].push(`${accepted}/${TRIALS}`);
    rows[2].push(`${heard}/${TRIALS}`);
    rows[3].push(ratioN ? `${((ratioSum / ratioN) * 100).toFixed(2)}%` : "-");
    rows[4].push(`${correct}/${TRIALS}  (oct ${octErr})`);
  }
  const p = (r) => r.map((c) => String(c).padStart(8)).join("");
  console.log(p(rows[0]));
  console.log(p(rows[1]));
  console.log(p(rows[2]));
  console.log(p(rows[3]));
  console.log(p(rows[4]));
  console.log();
}

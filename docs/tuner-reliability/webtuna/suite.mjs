import { analyse, calls, I32, F32, mem, ex } from "./harness.mjs";

const SR = 44100, N = 4096;
const H = [1, 0.5, 0.33, 0.25, 0.2, 0.16, 0.13];
function tone(freq, sr = SR, n = N, harm = H, noise = 0, decay = 0, dc = 0) {
  const o = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    let s = 0;
    for (let k = 0; k < harm.length; k++) { const f = freq * (k + 1); if (f < sr / 2) s += harm[k] * Math.sin(2 * Math.PI * f * i / sr); }
    o[i] = s * 0.2 * (decay ? Math.exp(-decay * i / sr) : 1) + dc;
  }
  if (noise) for (let i = 0; i < n; i++) o[i] += (Math.random() * 2 - 1) * noise;
  return o;
}
// run a steady stream of a signal and return the settled output
function settle(sig, idx, frames = 40, sr = SR) {
  let last;
  for (let k = 0; k < frames; k++) last = analyse(sig, idx, sr);
  return last;
}
const cents = (hz, ref) => 1200 * Math.log2(hz / ref);
const NOTE = (m) => 440 * Math.pow(2, (m - 69) / 12);
const fmt = (o) => `hz=${o.MeasuredPitchHz.toFixed(2).padStart(8)} midi=${String(o.MeasuredPitchMidi).padStart(4)} cents=${String(o.TuningErrorCents).padStart(5)} ratio=${o.InTuneRatio.toFixed(2)} str=${String(o.CurrentString).padStart(3)} hear=${o.CanHearANote ? "Y" : "n"} rms=${o.MicRms.toFixed(4)} pw=${o.PossibleWrongStringId}`;

console.log("###### 1. cents accuracy (chromatic mode, exact semitones) ######");
for (let m = 28; m <= 88; m += 4) {
  const f = NOTE(m);
  const o = settle(tone(f), -2, 30);
  console.log(` midi ${String(m).padStart(3)} f=${f.toFixed(3).padStart(9)}  ->  ${fmt(o)}   err=${cents(o.MeasuredPitchHz, f).toFixed(2)}c`);
}

console.log("\n###### 2. detune sweep, chromatic (true pitch vs reported) ######");
for (const c of [-50, -30, -10, -5, -1, 0, 1, 5, 10, 30, 50]) {
  const f = NOTE(45) * Math.pow(2, c / 1200);
  const o = settle(tone(f), -2, 30);
  console.log(` detune ${String(c).padStart(4)}c  ->  ${fmt(o)}   trueErr=${cents(o.MeasuredPitchHz, f).toFixed(2)}c`);
}

console.log("\n###### 3. guitar string targets: which wasm index maps to which note ######");
// the site sends reversed indices; brute-force all 0..5 with an E2 tone
for (const idx of [0, 1, 2, 3, 4, 5, -1, -2, -3]) {
  const o = settle(tone(NOTE(40)), idx, 30);
  console.log(` idx=${String(idx).padStart(3)} with E2(82.4) -> ${fmt(o)}`);
}

console.log("\n###### 4. each guitar string played, auto mode ######");
for (const m of [40, 45, 50, 55, 59, 64]) {
  const o = settle(tone(NOTE(m)), -1, 30);
  console.log(` ${NOTE(m).toFixed(2).padStart(7)}Hz midi${m} -> ${fmt(o)}`);
}

console.log("\n###### 5. sub-harmonic / octave robustness ######");
for (const [label, harm] of [
  ["pure sine (1 harm)", [1]],
  ["2 harmonics", [1, 0.5]],
  ["fundamental weak 1:0.3", [0.3, 1, 0.33, 0.25]],
  ["missing f0 (2nd harmonic only)", [0, 1, 0.5, 0.33]],
  ["3rd harmonic dominant", [0.05, 0.05, 1, 0.5, 0.33]],
  ["sawtooth-ish 8 harm", [1, .5, .33, .25, .2, .166, .143, .125]],
]) {
  const o = settle(tone(NOTE(40), SR, N, harm), -2, 30);
  console.log(` ${label.padEnd(28)} -> ${fmt(o)}  (true 82.41Hz midi40)`);
}

console.log("\n###### 6. noise robustness (SNR sweep on E2) ######");
for (const nz of [0, 0.01, 0.03, 0.1, 0.2, 0.4, 0.8]) {
  const o = settle(tone(NOTE(40), SR, N, H, nz), -2, 30);
  console.log(` noise ${String(nz).padStart(5)} (rms~${(nz / Math.sqrt(3)).toFixed(3)}) -> ${fmt(o)}`);
}

console.log("\n###### 7. level sensitivity (amplitude sweep, pure-ish tone) ######");
for (const a of [0.0001, 0.001, 0.01, 0.05, 0.1, 0.3, 0.9]) {
  const s = tone(NOTE(40)); for (let i = 0; i < N; i++) s[i] *= a / 0.2 * 0.2 / 0.2 * 1;
  const sig = new Float32Array(N); for (let i = 0; i < N; i++) sig[i] = s[i] * a;
  const o = settle(sig, -2, 30);
  console.log(` amp ${String(a).padStart(7)} -> ${fmt(o)}`);
}

console.log("\n###### 8. polyphony: two strings at once ######");
for (const [a, b] of [[40, 52], [40, 64], [45, 57], [40, 47]]) {
  const s1 = tone(NOTE(a)), s2 = tone(NOTE(b));
  const mix = new Float32Array(N); for (let i = 0; i < N; i++) mix[i] = s1[i] + s2[i];
  const o = settle(mix, -1, 30);
  console.log(` ${NOTE(a).toFixed(1)}(m${a}) + ${NOTE(b).toFixed(1)}(m${b}) -> ${fmt(o)}`);
}

console.log("\n###### 9. sample-rate invariance (E2, chromatic) ######");
for (const sr of [22050, 32000, 44100, 48000, 96000]) {
  const o = settle(tone(NOTE(40), sr, N), -2, 30, sr);
  console.log(` sr=${String(sr).padStart(6)} -> ${fmt(o)}  err=${cents(o.MeasuredPitchHz, NOTE(40)).toFixed(2)}c`);
}

console.log("\n###### 10. latency: frames to first CanHearANote ######");
for (const [label, sig, idx] of [["E2", tone(NOTE(40)), -2], ["silence", new Float32Array(N), -2], ["A4", tone(NOTE(69)), -2]]) {
  const seq = [];
  for (let k = 0; k < 25; k++) seq.push(analyse(sig, idx, SR).CanHearANote ? "Y" : ".");
  console.log(` ${label.padEnd(8)} ${seq.join("")}`);
}

console.log("\n###### 11. InTuneRatio ramp and gating ######");
{
  const sig = tone(NOTE(40));
  for (let k = 0; k < 22; k++) { const o = analyse(sig, -2, SR); console.log(`  f${String(k).padStart(2)} ratio=${o.InTuneRatio.toFixed(4)} hear=${o.CanHearANote ? "Y" : "n"} cents=${o.TuningErrorCents} str=${o.CurrentString}`); }
}
console.log("\nerrors:", calls.consoleError.slice(0, 5), "thrown:", calls.thrown.slice(0, 5));

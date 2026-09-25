import { mk, tone, NOTE, H } from "./iso.mjs";

const fmt = (o) => `hz=${o.MeasuredPitchHz} midi=${o.MeasuredPitchMidi} cents=${o.TuningErrorCents} ratio=${o.InTuneRatio.toFixed(3)} str=${o.CurrentString} hear=${o.CanHearANote ? "Y" : "n"} rms=${o.MicRms.toFixed(4)} pw=${o.PossibleWrongStringId}`;
const cents = (hz, ref) => 1200 * Math.log2(hz / ref);

console.log("###### A. cents accuracy, fresh instance per note, chromatic ######");
for (let m = 24; m <= 96; m += 2) {
  const f = NOTE(m);
  const { run } = mk();
  for (let k = 0; k < 30; k++) var o = run(tone(f), -2, 44100);
  console.log(` midi ${String(m).padStart(3)} f=${f.toFixed(2).padStart(9)} -> ${fmt(o)}  trueErr=${o.MeasuredPitchHz ? cents(o.MeasuredPitchHz, f).toFixed(1) : "n/a"}c`);
}

console.log("\n###### B. harmonic content robustness, fresh each, chromatic ######");
for (const [label, harm] of [
  ["1 harmonic (sine)", [1]],
  ["2 harmonics", [1, 0.5]],
  ["f0 weak (0.3 : 1)", [0.3, 1, 0.33, 0.25]],
  ["no f0 (0,1,0.5,0.33)", [0, 1, 0.5, 0.33]],
  ["3rd dominant", [0.05, 0.05, 1, 0.5, 0.33]],
  ["sawtooth 8", [1, .5, .33, .25, .2, .166, .143, .125]],
  ["odd only 5", [1, 0, 0.33, 0, 0.2]],
  ["square 4", [1, 0, 0, 0]],
]) {
  const { run } = mk();
  for (let k = 0; k < 30; k++) var o = run(tone(NOTE(40), 44100, 4096, harm), -2, 44100);
  console.log(` ${label.padEnd(22)} -> ${fmt(o)}  trueErr=${o.MeasuredPitchHz ? cents(o.MeasuredPitchHz, NOTE(40)).toFixed(1) : "n/a"}c`);
}

console.log("\n###### C. sub-harmonic trap: strong 2nd/3rd harmonic ######");
for (const [label, harm] of [
  ["equal 1:1", [1, 1, 0.5, 0.33]],
  ["2nd 3x stronger", [1, 3, 1, 0.5]],
  ["3rd 5x stronger", [1, 1, 5, 2]],
  ["5th 10x stronger", [1, 0.5, 0.33, 0.25, 10]],
]) {
  const { run } = mk();
  for (let k = 0; k < 30; k++) var o = run(tone(NOTE(40), 44100, 4096, harm), -2, 44100);
  console.log(` ${label.padEnd(20)} -> ${fmt(o)}  trueErr=${o.MeasuredPitchHz ? cents(o.MeasuredPitchHz, NOTE(40)).toFixed(1) : "n/a"}c`);
}

console.log("\n###### D. noise robustness, fresh each, chromatic E2 ######");
for (const nz of [0, 0.003, 0.01, 0.03, 0.1, 0.2, 0.3, 0.5, 1.0]) {
  const { run } = mk();
  for (let k = 0; k < 30; k++) var o = run(tone(NOTE(40), 44100, 4096, H, nz), -2, 44100);
  const snr = 20 * Math.log10(0.1735 / (nz / Math.sqrt(3)));
  console.log(` noise ${String(nz).padStart(5)} SNR~${snr.toFixed(1).padStart(6)}dB -> ${fmt(o)}  trueErr=${o.MeasuredPitchHz ? cents(o.MeasuredPitchHz, NOTE(40)).toFixed(1) : "n/a"}c`);
}

console.log("\n###### E. level sweep, fresh each ######");
for (const a of [1e-4, 1e-3, 0.005, 0.01, 0.02, 0.05, 0.1, 0.3, 0.6, 1.0]) {
  const { run } = mk();
  const base = tone(NOTE(40));
  const sig = new Float32Array(base.length); for (let i = 0; i < base.length; i++) sig[i] = base[i] * a * 5;
  for (let k = 0; k < 30; k++) var o = run(sig, -2, 44100);
  console.log(` peak~${(a * 5 * 2.57).toFixed(3).padStart(7)} -> ${fmt(o)}`);
}

console.log("\n###### F. two notes at once, fresh each, auto ######");
for (const [a, b] of [[40, 52], [40, 64], [45, 57], [40, 47], [40, 55], [45, 64]]) {
  const { run } = mk();
  const s1 = tone(NOTE(a)), s2 = tone(NOTE(b));
  const mix = new Float32Array(4096); for (let i = 0; i < 4096; i++) mix[i] = s1[i] + s2[i];
  for (let k = 0; k < 30; k++) var o = run(mix, -1, 44100);
  console.log(` m${a}+m${b} -> ${fmt(o)}`);
}

console.log("\n###### G. sample rate, fresh each ######");
for (const sr of [16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 192000]) {
  const { run } = mk();
  for (let k = 0; k < 30; k++) var o = run(tone(NOTE(40), sr, 4096), -2, sr);
  console.log(` sr=${String(sr).padStart(6)} -> ${fmt(o)}  trueErr=${o.MeasuredPitchHz ? cents(o.MeasuredPitchHz, NOTE(40)).toFixed(1) : "n/a"}c`);
}

console.log("\n###### H. buffer size sensitivity (site always sends 4096) ######");
for (const n of [1024, 2048, 4096, 8192, 16384]) {
  const { run } = mk();
  for (let k = 0; k < 30; k++) var o = run(tone(NOTE(40), 44100, n), -2, 44100);
  console.log(` N=${String(n).padStart(6)} -> ${fmt(o)}  trueErr=${o.MeasuredPitchHz ? cents(o.MeasuredPitchHz, NOTE(40)).toFixed(1) : "n/a"}c`);
}

console.log("\n###### I. latency & ratio ramp, fresh ######");
for (const [lbl, sig] of [["E2", tone(NOTE(40))], ["A4", tone(NOTE(69))], ["silence", new Float32Array(4096)]]) {
  const { run } = mk();
  const rows = [];
  for (let k = 0; k < 20; k++) { const o = run(sig, -2, 44100); rows.push(`${o.CanHearANote ? "Y" : "."}${o.InTuneRatio.toFixed(2)}/${o.CurrentString}`); }
  console.log(` ${lbl.padEnd(8)} ${rows.join(" ")}`);
}

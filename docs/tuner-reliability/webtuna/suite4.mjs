import { mk, tone, NOTE, H } from "./iso.mjs";
const cents = (hz, ref) => 1200 * Math.log2(hz / ref);
const fmt = (o) => `hz=${o.MeasuredPitchHz} midi=${o.MeasuredPitchMidi} cents=${String(o.TuningErrorCents).padStart(5)} ratio=${o.InTuneRatio.toFixed(2)} str=${String(o.CurrentString).padStart(3)} hear=${o.CanHearANote ? "Y" : "n"} rms=${o.MicRms.toFixed(4)} pw=${o.PossibleWrongStringId}`;

console.log("###### 1. note gate: sweep input level, does CanHearANote follow MicRms? ######");
for (const a of [0.02, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.5, 0.8, 1.5, 3, 6]) {
  const { run } = mk();
  const base = tone(NOTE(40)); const sig = new Float32Array(4096);
  for (let i = 0; i < 4096; i++) sig[i] = base[i] * a;
  let o; for (let k = 0; k < 50; k++) o = run(sig, -1, 44100);
  console.log(` scale ${String(a).padStart(5)} -> ${fmt(o)}`);
}

console.log("\n###### 2. DC offset tolerance ######");
for (const dc of [0, 0.1, 0.5, 0.9, 2, -0.9, 5]) {
  const { run } = mk();
  const sig = tone(NOTE(40), 44100, 4096, H, 0, dc);
  let o; for (let k = 0; k < 50; k++) o = run(sig, -1, 44100);
  console.log(` dc ${String(dc).padStart(5)} -> ${fmt(o)}  err=${o.MeasuredPitchHz ? cents(o.MeasuredPitchHz, NOTE(40)).toFixed(1) : "n/a"}c`);
}

console.log("\n###### 3. InTuneRatio window: frames to 0.9 from a clean start ######");
for (const [lbl, sig, idx] of [
  ["E2 auto", tone(NOTE(40)), -1],
  ["A2 auto", tone(NOTE(45)), -1],
  ["E4 auto", tone(NOTE(64)), -1],
  ["A4 chrom", tone(NOTE(69)), -2],
]) {
  const { run } = mk();
  let first = -1, sat = -1;
  for (let k = 0; k < 40; k++) { const o = run(sig, idx, 44100); if (first < 0 && o.CanHearANote) first = k; if (sat < 0 && o.InTuneRatio > 0.9) sat = k; }
  console.log(` ${lbl.padEnd(9)} first note @frame ${first}, ratio>0.9 @frame ${sat}`);
}

console.log("\n###### 4. InTuneRatio vs detune (does it gate on cents?) ######");
for (const c of [0, 2, 5, 8, 10, 15, 20, 30, 50, 80, 120]) {
  const { run } = mk();
  const sig = tone(NOTE(40) * Math.pow(2, c / 1200));
  let o; for (let k = 0; k < 50; k++) o = run(sig, -1, 44100);
  console.log(` detune ${String(c).padStart(4)}c -> ${fmt(o)}`);
}

console.log("\n###### 5. PossibleWrongStringId: play a note while a string is selected ######");
for (const [lbl, f, idx] of [
  ["E2 tone, select B3(1)", NOTE(40), 1],
  ["E2 tone, select E4(0)", NOTE(40), 0],
  ["E2 tone, select E2(5)", NOTE(40), 5],
  ["E2 tone, auto", NOTE(40), -1],
  ["A2 tone, select D3(2)", NOTE(45), 2],
  ["C4 tone, select E2(5)", NOTE(60), 5],
  ["C4 tone, select B3(1)", NOTE(60), 1],
]) {
  const { run } = mk();
  let o; for (let k = 0; k < 50; k++) o = run(tone(f), idx, 44100);
  console.log(` ${lbl.padEnd(24)} -> ${fmt(o)}`);
}

console.log("\n###### 6. high register / sub-octave behaviour (12-string-ish freqs) ######");
for (const m of [64, 71, 76, 83, 88, 95, 100, 107]) {
  const { run } = mk();
  let o; for (let k = 0; k < 60; k++) o = run(tone(NOTE(m)), -2, 44100);
  console.log(` m${m} ${NOTE(m).toFixed(1).padStart(8)}Hz -> ${fmt(o)}  err=${o.MeasuredPitchHz ? cents(o.MeasuredPitchHz, NOTE(m)).toFixed(0) : "n/a"}c`);
}

console.log("\n###### 7. very low E (32.7Hz, 5-string bass B0) in chromatic ######");
for (const m of [24, 26, 28, 30, 33, 36]) {
  const { run } = mk();
  let o; for (let k = 0; k < 80; k++) o = run(tone(NOTE(m)), -2, 44100);
  console.log(` m${m} ${NOTE(m).toFixed(2).padStart(7)}Hz -> ${fmt(o)}  err=${o.MeasuredPitchHz ? cents(o.MeasuredPitchHz, NOTE(m)).toFixed(0) : "n/a"}c`);
}

console.log("\n###### 8. does it track a glide (pitch sweep)? ######");
{
  const { run } = mk();
  for (let k = 0; k < 40; k++) run(tone(NOTE(40)), -1, 44100);
  const out = [];
  for (let st = 0; st <= 20; st += 4) {
    const f = NOTE(40) * Math.pow(2, st / 12);
    let o; for (let k = 0; k < 12; k++) o = run(tone(f), -1, 44100);
    out.push(`+${st}st:${o.MeasuredPitchMidi}m/${o.TuningErrorCents}c`);
  }
  console.log("  " + out.join("  "));
}

console.log("\n###### 9. MicRms scaling law ######");
for (const a of [0.05, 0.1, 0.2, 0.4, 0.8]) {
  const { run } = mk();
  const base = tone(NOTE(40)); const sig = new Float32Array(4096);
  for (let i = 0; i < 4096; i++) sig[i] = base[i] * a;
  let o; for (let k = 0; k < 50; k++) o = run(sig, -1, 44100);
  const inRms = a * 0.8674;
  console.log(` scale ${String(a).padStart(4)} inputRMS~${inRms.toFixed(4)} -> MicRms=${o.MicRms.toFixed(5)}  ratio=${(o.MicRms / inRms).toFixed(3)}`);
}

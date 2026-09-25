import { mk, tone, NOTE, H } from "./iso.mjs";
const fmt = (o) => `hz=${o.MeasuredPitchHz} midi=${o.MeasuredPitchMidi} cents=${String(o.TuningErrorCents).padStart(5)} ratio=${o.InTuneRatio.toFixed(2)} str=${String(o.CurrentString).padStart(3)} hear=${o.CanHearANote ? "Y" : "n"}`;
const cents = (hz, ref) => 1200 * Math.log2(hz / ref);

console.log("###### chromatic-mode detection floor vs harmonic content, 100 frames ######");
console.log("freq   | pure sine                 | 3 harmonics [1,.5,.33]     | 7 harmonics");
for (const f of [40, 50, 60, 70, 80, 82.41, 90, 100, 110, 130, 150, 180, 220, 330, 440, 660, 880, 1320, 1760, 2637]) {
  const res = [];
  for (const harm of [[1], [1, .5, .33], H]) {
    const { run } = mk();
    let o; for (let k = 0; k < 100; k++) o = run(tone(f, 44100, 4096, harm), -2, 44100);
    res.push(o.CanHearANote ? `${o.MeasuredPitchHz}Hz/${o.MeasuredPitchMidi}m err=${cents(o.MeasuredPitchHz, f).toFixed(0)}c` : "-");
  }
  console.log(String(f).padStart(6), "|", res[0].padEnd(24), "|", res[1].padEnd(26), "|", res[2]);
}

console.log("\n###### same frequencies in AUTO (string) mode, 100 frames, 7 harm ######");
for (const f of [60, 70, 80, 82.41, 90, 98, 110, 147, 196, 247, 330, 440, 660]) {
  const { run } = mk();
  let o; for (let k = 0; k < 100; k++) o = run(tone(f, 44100, 4096, H), -1, 44100);
  console.log(String(f).padStart(6), "->", fmt(o), o.MeasuredPitchHz ? ` err=${cents(o.MeasuredPitchHz, f).toFixed(1)}c` : "");
}

console.log("\n###### chromatic, 7 harm, sweep 60..1000 Hz fine, 60 frames ######");
let fails = [];
for (let f = 60; f <= 1000; f *= 1.02) {
  const { run } = mk();
  let o; for (let k = 0; k < 60; k++) o = run(tone(f, 44100, 4096, H), -2, 44100);
  const e = o.CanHearANote ? cents(o.MeasuredPitchHz, f) : NaN;
  if (!o.CanHearANote || Math.abs(e) > 25) fails.push(`${f.toFixed(1)}Hz -> ${o.CanHearANote ? o.MeasuredPitchHz + "Hz err=" + e.toFixed(0) + "c" : "NO NOTE"}`);
}
console.log("problem frequencies (no note, or >25c error):");
console.log(fails.length ? fails.join("\n") : "  none");

console.log("\n###### A4 reference sanity: is the reference 440 exactly? ######")
for (const f of [438, 439, 440, 441, 442]) {
  const { run } = mk();
  let o; for (let k = 0; k < 60; k++) o = run(tone(f, 44100, 4096, H), -2, 44100);
  console.log(` ${f}Hz -> ${fmt(o)}  err=${cents(o.MeasuredPitchHz, f).toFixed(1)}c`);
}

console.log("\n###### per-string accuracy, AUTO mode, 7 harm, 80 frames ######")
for (const m of [40, 45, 50, 55, 59, 64]) {
  const { run } = mk();
  let o; for (let k = 0; k < 80; k++) o = run(tone(NOTE(m), 44100, 4096, H), -1, 44100);
  console.log(` m${m} ${NOTE(m).toFixed(2).padStart(7)}Hz -> ${fmt(o)}  err=${o.MeasuredPitchHz ? cents(o.MeasuredPitchHz, NOTE(m)).toFixed(1) : "n/a"}c  (str ${o.CurrentString} = ${["E4","B3","G3","D3","A2","E2"][o.CurrentString]})`);
}

import { mk, tone, NOTE, H } from "./iso.mjs";
const { run, I, F, mem } = mk();
const I32 = I;
run(tone(NOTE(40)), -1, 44100);
const g = I32()[36140 >> 2], k = I32()[g >> 2];

// COLA of the symmetric 0.54/0.46 window at hop 2048
let vf = -1;
for (let a = 1024; a < 1 << 20; a += 4) if (I32()[a >> 2] === 13404) { vf = a; break; }
const J = vf - 224;
const wb = I32()[(J >> 2) + 48], we = I32()[(J >> 2) + 49];
const w = Array.from(F(wb, (we - wb) >> 2));
let mn = 1e9, mx = -1e9, sum = 0, cnt = 0;
for (let i = 0; i + 2048 < w.length; i++) { const s = w[i] + w[i + 2048]; mn = Math.min(mn, s); mx = Math.max(mx, s); sum += s; cnt++; }
console.log(`window len ${w.length}, hop 2048, overlap sum: min=${mn.toFixed(6)} max=${mx.toFixed(6)} mean=${(sum / cnt).toFixed(6)}  (ripple ${(((mx - mn) / ((mx + mn) / 2)) * 100).toFixed(2)}%)`);

// -3 dB points of the window spectrum (coherent gain of the main lobe)
let peak = 0;
for (let i = 0; i < 4096; i++) peak = Math.max(peak, w[i]);
// Hann-window main lobe null-to-null = 4 bins; -3dB bandwidth ~ 1.44 bins for Hann, ~1.21 for Hamming
console.log("window peak (coherent gain) =", peak.toFixed(4), "  power gain =", (w.reduce((s, v) => s + v * v, 0) / w.length).toFixed(4));

// MicRms decay after the tone stops
console.log("\nMicRms decay after the note stops (peak-hold over a 64-frame ring, 2 frames/call => 32 calls):");
for (let k = 0; k < 25; k++) run(tone(NOTE(40)), -1, 44100);
for (let k = 0; k < 60; k++) {
  const o = run(new Float32Array(4096), -1, 44100);
  if (k % 4 === 0 || k < 6) console.log(`  call ${String(k).padStart(2)} after stop: MicRms=${o.MicRms.toFixed(5)} hear=${o.CanHearANote ? "Y" : "n"} ratio=${o.InTuneRatio.toFixed(2)} str=${o.CurrentString} hz=${o.MeasuredPitchHz}`);
}

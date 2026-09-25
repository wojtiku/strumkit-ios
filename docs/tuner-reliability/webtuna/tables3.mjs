import { analyse, I32, F32, cstr, ex, mem } from "./harness.mjs";
const SR = 44100, N = 4096;
function tone(freq, sr, n) { const o = new Float32Array(n); for (let i = 0; i < n; i++) { let s = 0; const h = [1, .5, .33, .25, .2, .16, .13]; for (let k = 0; k < h.length; k++) { const f = freq * (k + 1); if (f < sr / 2) s += h[k] * Math.sin(2 * Math.PI * f * i / sr); } o[i] = s * 0.2; } return o; }
for (let k = 0; k < 20; k++) analyse(tone(82.4069, SR, N), -1, SR);

const I = I32();
const pLo = I[36100 >> 2], pCtr = I[36112 >> 2], pHi = I[36124 >> 2];
console.log("ptrs:", pLo, pCtr, pHi, " caps:", I[36108 >> 2], I[36120 >> 2], I[36132 >> 2]);
const lo = Array.from(F32(pLo, 56)), ctr = Array.from(F32(pCtr, 56)), hi = Array.from(F32(pHi, 56));
const show = (n, a) => console.log(n.padEnd(6), a.map((v, i) => `${i}:${v.toFixed(2)}`).join(" "));
show("lo", lo); console.log(); show("ctr", ctr); console.log(); show("hi", hi);

const calc = (off) => Array.from({ length: 56 }, (_, k) => { const a = 2.318973 + 0.5 * k; return (Math.pow(10, Math.max(0, a + off) * 0.046804) - 1) * 228.937714; });
for (const [nm, off, got] of [["lo", -1, lo], ["ctr", 0, ctr], ["hi", 1, hi]]) {
  const want = calc(off);
  let e = 0; for (let k = 0; k < 56; k++) e = Math.max(e, Math.abs(want[k] - got[k]));
  console.log(`\n${nm}: max err vs my formula = ${e.toExponential(3)}`);
  if (e > 0.01) { console.log("  want", want.slice(20, 28).map((v) => v.toFixed(3))); console.log("  got ", got.slice(20, 28).map((v) => v.toFixed(3))); }
}
console.log("\n--- interpreting the tables as BIN indices (sr=44100, N=4096) ---");
const k = 4096 / 44100;
console.log("lo[0..5] :", lo.slice(0, 6).map((v) => (v * k).toFixed(2)).join(", "));
console.log("ctr[0..5]:", ctr.slice(0, 6).map((v) => (v * k).toFixed(2)).join(", "));
console.log("ctr[20..25]:", ctr.slice(20, 26).map((v) => (v * k).toFixed(2)).join(", "));
console.log("ctr[50..55]:", ctr.slice(50, 56).map((v) => (v * k).toFixed(2)).join(", "));
console.log("hi[55]:", (hi[55] * k).toFixed(2));
console.log("\n--- as Hz (bin*sr/N) ---");
console.log("ctr in Hz:", ctr.slice(0, 8).map((v) => (v * 44100 / 4096).toFixed(1)).join(", "));
console.log("ctr[20..27] in Hz:", ctr.slice(20, 28).map((v) => (v * 44100 / 4096).toFixed(1)).join(", "));
console.log("ctr[50..55] in Hz:", ctr.slice(50, 56).map((v) => (v * 44100 / 4096).toFixed(1)).join(", "));
console.log("\nratio ctr[k+1]/ctr[k]:", [0, 10, 20, 30, 40, 50].map((i) => (ctr[i + 1] / ctr[i]).toFixed(4)).join(", "));
console.log("=> semitones per band:", [0, 10, 20, 30, 40, 50].map((i) => (12 * Math.log2(ctr[i + 1] / ctr[i])).toFixed(3)).join(", "));

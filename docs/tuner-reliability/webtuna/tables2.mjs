import { analyse, I32, F32, F64, cstr, ex, mem } from "./harness.mjs";

const SR = 44100, N = 4096;
function tone(freq, sr, n) { const o = new Float32Array(n); for (let i = 0; i < n; i++) { let s = 0; const h = [1, .5, .33, .25, .2, .16, .13]; for (let k = 0; k < h.length; k++) { const f = freq * (k + 1); if (f < sr / 2) s += h[k] * Math.sin(2 * Math.PI * f * i / sr); } o[i] = s * 0.2; } return o; }
// warm up so the lazy statics get built
for (let k = 0; k < 20; k++) analyse(tone(82.4069, SR, N), -1, SR);

const g = (a) => I32()[a >> 2];
const T = (a) => Array.from(F32(a, 56));
const base = 36100;
console.log("T_lo  @%d (lower edge)\n", base, T(base).map((v, i) => `${i}:${v.toFixed(2)}`).join(" "));
console.log("\nT_ctr @%d (centre)\n", base + 12, T(base + 12).map((v, i) => `${i}:${v.toFixed(2)}`).join(" "));
console.log("\nT_hi  @%d (upper edge)\n", base + 24, T(base + 24).map((v, i) => `${i}:${v.toFixed(2)}`).join(" "));

// reproduce f_rs maths
const f = (a) => { let e = 0, n = 0; while (true) { const x = a[n]; n++; if (x === 0 || Math.abs(x) >= 1e30) break; e += x * x; } return Math.sqrt(e / n); };
const calc = (off) => Array.from({ length: 56 }, (_, k) => { const a = 2.318973 + 0.5 * k; return (Math.pow(10, Math.max(0, a + off) * 0.046804) - 1) * 228.937714; });
for (const [nm, off, addr] of [["lo", -1, base], ["ctr", 0, base + 12], ["hi", +1, base + 24]]) {
  const want = calc(off), got = T(addr);
  let maxerr = 0; for (let k = 0; k < 56; k++) maxerr = Math.max(maxerr, Math.abs(want[k] - got[k]));
  console.log(`check ${nm}: max abs err = ${maxerr}`);
  if (maxerr > 0.01) console.log("  want", want.slice(0, 8).map((v) => v.toFixed(3)), "\n  got ", got.slice(0, 8).map((v) => v.toFixed(3)));
}
console.log("\nfirst 8 values:", calc(0).slice(0, 8).map((v) => v.toFixed(3)).join(", "));
console.log("bin scale for sr=44100 fft=4096:", (4096 / 44100).toFixed(6));
console.log("=> centre bins:", calc(0).map((v) => (v * 4096 / 44100).toFixed(1)).slice(0, 12).join(", "));
console.log("=> hi bins[55]:", (calc(1)[55] * 4096 / 44100).toFixed(1), " lo bins[0]:", (calc(-1)[0] * 4096 / 44100).toFixed(2));
console.log("\nratio between consecutive centres:", (calc(0)[1] / calc(0)[0]).toFixed(5), (calc(0)[20] / calc(0)[19]).toFixed(5), (calc(0)[55] / calc(0)[54]).toFixed(5));
console.log("centre[0] as Hz @44100:", (calc(0)[0] * 4096 / 44100 * 44100 / 4096).toFixed(2));

import { mk, tone, NOTE, H } from "./iso.mjs";
const { run, I, F, mem } = mk();
const I32 = I;
for (let k = 0; k < 30; k++) run(tone(NOTE(40)), -1, 44100);
// find the Ooura_FFT object (vtable 13404 at offset 224 of the 288-byte object)
let found = -1;
for (let a = 1024; a < 1 << 20; a += 4) if (I32()[a >> 2] === 13404) { found = a; break; }
console.log("vtable 13404 (Yousician::Ooura_FFT) found at byte", found, "-> object base", found - 224);
const J = found - 224;
console.log("J fields:");
for (let i = 0; i < 72; i += 6) {
  const row = [];
  for (let j = i; j < i + 6; j++) { const v = I32()[(J >> 2) + j]; const f = F(J + j * 4, 1)[0]; row.push(`${j}:${v}${Math.abs(f) < 1e5 && isFinite(f) ? "=" + f.toFixed(3) : ""}`); }
  console.log("  " + row.join("  "));
}
// J[48],J[49] = the window vector (begin/end ptrs)
const wb = I32()[(J >> 2) + 48], we = I32()[(J >> 2) + 49];
console.log("\nwindow vector:", wb, we, "len", (we - wb) >> 2);
if (wb > 1024 && we > wb) {
  const w = Array.from(F(wb, (we - wb) >> 2));
  console.log("  w[0..7]  :", w.slice(0, 8).map((v) => v.toFixed(6)).join(", "));
  console.log("  w[mid±3]:", w.slice((w.length >> 1) - 3, (w.length >> 1) + 4).map((v) => v.toFixed(6)).join(", "));
  console.log("  w[end-4..]:", w.slice(-4).map((v) => v.toFixed(6)).join(", "));
  const n = w.length - 1;
  let err = 0;
  for (let i = 0; i < w.length; i++) err = Math.max(err, Math.abs(w[i] - (0.54 - 0.46 * Math.cos((2 * Math.PI * i) / n))));
  console.log("  max err vs 0.54-0.46cos(2pi n/(N-1)) =", err.toExponential(3));
  let err2 = 0;
  for (let i = 0; i < w.length; i++) err2 = Math.max(err2, Math.abs(w[i] - (0.54 - 0.46 * Math.cos((2 * Math.PI * i) / w.length))));
  console.log("  max err vs 0.54-0.46cos(2pi n/N)     =", err2.toExponential(3));
  // COLA check at 50% overlap
  let s = 0, mn = 1e9, mx = -1e9;
  for (let i = 0; i < n; i++) { s = w[i] + w[i + n / 2]; mn = Math.min(mn, s); mx = Math.max(mx, s); }
  console.log("  50%-overlap sum: min", mn.toFixed(6), "max", mx.toFixed(6));
}
// J[69] = FFT input buffer, J[11]/J[10] = spectrum range
console.log("\nJ[4]=", I32()[(J >> 2) + 4], " J[1]=", I32()[(J >> 2) + 1], " J[3] float=", F(J + 12, 1)[0], " J[0] float=", F(J, 1)[0]);
console.log("J[10]=", I32()[(J >> 2) + 10], " J[11]=", I32()[(J >> 2) + 11], " (spectrum bin range)");
console.log("J[5]=", I32()[(J >> 2) + 5], " J[6]=", I32()[(J >> 2) + 6], " J[14..16]=", I32()[(J >> 2) + 14], I32()[(J >> 2) + 15], I32()[(J >> 2) + 16]);
const sp = I32()[(J >> 2) + 69];
if (sp > 1024) {
  const s = Array.from(F(sp, 24));
  console.log("J[69] first 24 floats (FFT in/out buffer):", s.map((v) => v.toFixed(5)).join(", "));
  const s2 = Array.from(F(sp + 24 * 4, 40));
  console.log("   next 40:", s2.map((v) => v.toFixed(3)).join(", "));
}

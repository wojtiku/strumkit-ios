import { mk, tone, NOTE, H } from "./iso.mjs";
const { run, I, F, mem } = mk();
const I32 = () => I();
for (let k = 0; k < 60; k++) run(tone(NOTE(40), 44100, 4096, H), -1, 44100); // settle on E2, auto

const g = I32()[36140 >> 2];
console.log("engine g =", g);
const k = I32()[g >> 2];
console.log("inner k = g[0] =", k);
console.log("\n--- inner object k[0..79] (i32 | float reinterpreted) ---");
for (let row = 0; row < 80; row += 8) {
  let a = "", b = "";
  for (let i = row; i < row + 8; i++) {
    const v = I32()[(k >> 2) + i];
    a += String(v).padStart(11);
    b += (Number.isInteger(v) && Math.abs(v) < 0x40000000 && v !== 0 ? "" : (F(k + i * 4, 1)[0].toFixed(4) + "/f").padStart(11));
  }
  console.log(`k[${String(row).padStart(2)}] ${a}`);
  console.log(`       ${b}`);
}
console.log("\n--- engine object g[0..79] ---");
for (let row = 0; row < 80; row += 8) {
  let a = "", b = "";
  for (let i = row; i < row + 8; i++) {
    const v = I32()[(g >> 2) + i];
    a += String(v).padStart(11);
    b += (Number.isInteger(v) && Math.abs(v) < 0x40000000 && v !== 0 ? "" : (F(g + i * 4, 1)[0].toFixed(4) + "/f").padStart(11));
  }
  console.log(`g[${String(row).padStart(2)}] ${a}`);
  console.log(`       ${b}`);
}
console.log("\n--- engine g[100..200] (the sub-object at g+100 used by f_qk) ---");
for (let row = 100; row < 200; row += 8) {
  let a = "", b = "";
  for (let i = row; i < row + 8; i++) {
    const v = I32()[(g >> 2) + i];
    a += String(v).padStart(11);
    b += (Number.isInteger(v) && Math.abs(v) < 0x40000000 && v !== 0 ? "" : (F(g + i * 4, 1)[0].toFixed(4) + "/f").padStart(11));
  }
  console.log(`g[${String(row).padStart(3)}] ${a}`);
  console.log(`        ${b}`);
}
console.log("\n--- the precomputed candidate frequency table (config o[32..]) ---");
// o is freed after the call; instead read k[?]. Show k[8] array if it is a freq table
const p = I32()[(k >> 2) + 8];
if (p > 1024 && p < 1 << 21) {
  const n = I32()[(k >> 2) + 7];
  console.log(`k[8] = ${p} (candidate table), k[7] = ${n}`);
  const t = Array.from(F(p, Math.min(n, 40)));
  console.log("  first 40:", t.map((v) => v.toFixed(2)).join(", "));
  console.log("  as midi:", t.map((v) => (12 * Math.log2(v / 440) + 69).toFixed(2)).slice(0, 20).join(", "));
}
console.log("\n--- static 56-band tables after init ---");
for (const [nm, a] of [["T_lo", 36100], ["T_ctr", 36112], ["T_hi", 36124]]) {
  const ptr = I32()[a >> 2];
  const t = Array.from(F(ptr, 56));
  console.log(nm, "ptr", ptr, ":", t.slice(0, 8).map((v) => v.toFixed(1)).join(", "), "...", t.slice(-4).map((v) => v.toFixed(1)).join(", "));
}
console.log("\n--- k[35] rms ring buffer (k[38]=write idx, k[3]? cap) ---");
const rp = I32()[(k >> 2) + 35];
console.log("k[35] =", rp, "k[38] =", I32()[(k >> 2) + 38], "k[40] =", F(k + 160, 1)[0]);
if (rp > 1024 && rp < 1 << 21) {
  console.log("  ring:", Array.from(F(rp, 32)).map((v) => v.toFixed(5)).join(", "));
}
console.log("\n--- k[11] array (used for the min-tracker) ---");
const p11 = I32()[(k >> 2) + 11];
console.log("k[11] =", p11, p11 > 1024 && p11 < 1 << 21 ? Array.from(F(p11, 24)).map((v) => v.toFixed(4)).join(", ") : "");
console.log("\nk[1] =", I32()[(k >> 2) + 1], " k[2] =", I32()[(k >> 2) + 2], " k[3] =", I32()[(k >> 2) + 3], " k[4] =", F(k + 16, 1)[0], " k[5] =", I32()[(k >> 2) + 5], " k[6] =", I32()[(k >> 2) + 6]);
console.log("k[10] =", I32()[(k >> 2) + 10], " k[9] =", I32()[(k >> 2) + 9], " k[12] =", I32()[(k >> 2) + 12]);
console.log("k[14] =", I32()[(k >> 2) + 14], " k[15] =", I32()[(k >> 2) + 15], " k[16] =", I32()[(k >> 2) + 16]);

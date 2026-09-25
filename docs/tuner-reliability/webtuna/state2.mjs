import { mk, tone, NOTE, H } from "./iso.mjs";
const { run, I, F, mem } = mk();
const I32 = I;
for (let k = 0; k < 60; k++) run(tone(NOTE(40), 44100, 4096, H), -1, 44100);

function dumpObj(name, base, n) {
  console.log(`\n--- ${name} @${base} ---`);
  for (let row = 0; row < n; row += 4) {
    const parts = [];
    for (let i = row; i < Math.min(row + 4, n); i++) {
      const iv = I32()[(base >> 2) + i];
      const fv = F(base + i * 4, 1)[0];
      const looksF = Number.isFinite(fv) && Math.abs(fv) < 1e6 && (fv === 0 || (Math.abs(fv) >= 1e-4 && Math.abs(fv) < 1e5));
      const isPtr = iv > 1024 && iv < 1 << 21;
      const b8 = new Uint8Array(mem.buffer, base + i * 4, 1)[0];
      const b8b = new Uint8Array(mem.buffer, base + i * 4 + 1, 1)[0];
      parts.push(`${String(i).padStart(3)}:${isPtr ? "p" + iv : String(iv).padStart(9)}${looksF ? " (" + fv.toFixed(4) + ")" : ""}${b8 ? " {" + b8 + "," + b8b + "}" : ""}`);
    }
    console.log("  " + parts.join("  "));
  }
}
const g = I32()[36140 >> 2], k = I32()[g >> 2];
dumpObj("ENGINE g", g, 64);
dumpObj("INNER k", k, 80);
dumpObj("ENGINE g (rest)", g + 64 * 4, 160);
console.log("\nglobals: 36136 =", new Uint8Array(mem.buffer, 36136, 1)[0], " 36140 =", I32()[36140 >> 2], " 36080.. =", I32()[36080 >> 2], I32()[36084 >> 2], I32()[36088 >> 2], I32()[36092 >> 2]);
console.log("static int trios 36100/36112/36124:", I32()[36100 >> 2], I32()[36104 >> 2], I32()[36108 >> 2], "|", I32()[36112 >> 2], I32()[36116 >> 2], I32()[36120 >> 2], "|", I32()[36124 >> 2], I32()[36128 >> 2], I32()[36132 >> 2]);
console.log("36128..36160 i32:", Array.from({ length: 9 }, (_, i) => I32()[36128 >> 2 + i]).join(", "));
console.log("36136..36160 as float:", Array.from({ length: 7 }, (_, i) => F(36136 + i * 4, 1)[0].toFixed(4)).join(", "));
console.log("\nstring MIDI table candidate at g+72:", Array.from({ length: 10 }, (_, i) => I32()[(g >> 2) + 72 + i]).join(", "));
console.log("k[7]=", I32()[(k >> 2) + 7], "k[6]=", I32()[(k >> 2) + 6], "k[16]=", I32()[(k >> 2) + 16], "k[14]=", I32()[(k >> 2) + 14], "k[15]=", I32()[(k >> 2) + 15]);
console.log("k[36] (ring cap)=", I32()[(k >> 2) + 36], "k[38] (idx)=", I32()[(k >> 2) + 38], "k[39] (write pos)=", I32()[(k >> 2) + 39]);
console.log("g[47]=", I32()[(g >> 2) + 47], "g[48]=", I32()[(g >> 2) + 48], "g[28]=", I32()[(g >> 2) + 28], "g[13]=", I32()[(g >> 2) + 13]);
console.log("k[4] float =", F(k + 16, 1)[0], " k[5] float =", F(k + 20, 1)[0], " k[3] float =", F(k + 12, 1)[0], " k[0] float =", F(k, 1)[0]);
console.log("k[40] float =", F(k + 160, 1)[0], " k[41] int =", I32()[(k >> 2) + 41], " k[42] float =", F(k + 168, 1)[0], " k[44] int =", I32()[(k >> 2) + 44], "k[45] =", I32()[(k >> 2) + 45]);
console.log("k[3] as int =", I32()[(k >> 2) + 3], "k[5] as int =", I32()[(k >> 2) + 5]);
const rmsRing = I32()[(k >> 2) + 35];
console.log("rms ring (64):", Array.from(F(rmsRing, 64)).slice(0, 8).map((v) => v.toFixed(6)).join(", "), "...");
const t11 = I32()[(k >> 2) + 11];
console.log("k[11] table (48):", Array.from(F(t11, 48)).map((v) => v.toFixed(4)).join(", "));
const cand = I32()[(k >> 2) + 8];
const n = I32()[(k >> 2) + 7] * 15;
console.log("candidate table len", n, "-> midi", Array.from(F(cand, n)).filter((_, i) => i % 15 === 0).map((v) => (12 * Math.log2(v / 440) + 69).toFixed(1)).join(", "));
console.log("candidate freq range:", F(cand, 1)[0].toFixed(3), "..", F(cand + (n - 1) * 4, 1)[0].toFixed(3));

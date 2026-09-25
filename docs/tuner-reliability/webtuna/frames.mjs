import { mk, tone, NOTE, H } from "./iso.mjs";
const { run, I, F } = mk();
const I32 = I;
run(tone(NOTE(40)), -1, 44100);            // create the engine singleton first
const g = I32()[36140 >> 2], k = I32()[g >> 2];
const rmsRing = I32()[(k >> 2) + 35];
console.log("engine g =", g, " inner k =", k, " rmsRing =", rmsRing);
console.log("k[1] (frame/ring size) =", I32()[(k >> 2) + 1], " k[2] (hop) =", I32()[(k >> 2) + 2], " k[36] (rms ring len) =", I32()[(k >> 2) + 36]);
console.log("\ncall | rmsRingIdx k[38] | rmsRing[0..3]                          | ratio | g[10] pitch idx | g[48]/g[47] | k[39] write");
for (let c = 0; c < 14; c++) {
  const o = run(tone(NOTE(40)), -1, 44100);
  const idx = I32()[(k >> 2) + 38];
  const ring = Array.from(F(rmsRing, 4)).map((v) => v.toFixed(6)).join(", ");
  console.log(` ${String(c).padStart(4)} | ${String(idx).padStart(3)}                   | ${ring.padEnd(36)} | ${o.InTuneRatio.toFixed(3)} | ${String(I32()[(g >> 2) + 10]).padStart(3)}              | ${I32()[(g >> 2) + 48]}/${I32()[(g >> 2) + 47]}        | ${I32()[(k >> 2) + 39]}`);
}
console.log("\nfilterbank bottom edge vs bass register:");
const T = (a) => Array.from(F(I32()[a >> 2], 56));
const lo = T(36100), ctr = T(36112), hi = T(36124);
for (const sr of [44100, 48000]) {
  const s = 8192 / sr;
  console.log(` sr=${sr}: bins ${Math.floor(lo[0] * s) + 1}..${Math.floor(hi[55] * s) + 1}  =  ${(Math.floor(lo[0] * s) + 1) / s}..${(Math.floor(hi[55] * s) + 1) / s} Hz   (band0 centre ${ctr[0] / s} Hz)`);
}
console.log(" bass B0=30.87 Hz, E1=41.20 Hz, 12-string high E=1975.5 Hz, 7-string B=2469.3 Hz");

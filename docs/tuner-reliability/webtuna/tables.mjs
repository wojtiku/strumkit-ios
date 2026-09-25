import { ex, mem, U8, F32, F64, cstr, log } from "./harness.mjs";

const I32 = () => new Int32Array(mem.buffer);
function dumpF32(a, n, label) {
  const f = new Float32Array(mem.buffer, a, n);
  console.log(`${label} @${a}:`, Array.from(f).map((x) => x.toFixed(6)).join(", "));
}
function dumpI32(a, n, label) {
  const f = new Int32Array(mem.buffer, a, n);
  console.log(`${label} @${a}:`, Array.from(f).join(", "));
}
function dumpF64(a, n, label) {
  const f = new Float64Array(mem.buffer, a, n);
  console.log(`${label} @${a}:`, Array.from(f).map((x) => x.toFixed(8)).join(", "));
}
const g = (a) => I32()[a >> 2];

for (const a of [36080, 36096, 36100, 36108, 36112, 36120, 36124, 36132, 36136, 36140, 36144]) {
  dumpI32(a, 4, "i32");
}
console.log("--- as floats ---");
for (const a of [36096, 36104, 36112, 36120, 36124, 36132, 36136, 36140, 36144]) dumpF32(a, 4, "f32");
console.log("\n=== 56-entry tables (36112 / 36124 / 36100) ===");
dumpF32(36112, 56, "T36112");
dumpF32(36124, 56, "T36124");
dumpF32(36100, 56, "T36100");
console.log("\n=== 36136 / 36140 / 36144 as i32+f32 ===");
dumpI32(36136, 12, "i32");
dumpF32(36136, 12, "f32");
dumpF64(36136, 6, "f64");
console.log("\n=== vtable-ish ptrs ===");
for (const a of [34940, 34676, 14752, 14688, 14268, 13212, 31408, 30940, 13316, 13504, 13404, 36144, 35240, 35280, 35392]) {
  console.log(" ", a, "->", g(a), "|", g(a + 4), "|", g(a + 8));
}
console.log("\n=== strings near 5180 / 5215 / 5691 ===");
for (const a of [5180, 5215, 4092, 4100, 4114, 4122, 4516, 5699, 9719, 4092]) console.log(" ", a, JSON.stringify(cstr(a)));

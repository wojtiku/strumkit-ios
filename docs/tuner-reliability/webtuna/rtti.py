#!/usr/bin/env python3
"""Reconstruct the C++ class hierarchy of WebTuna.wasm from RTTI + vtables (validated)."""
import json, re, struct, subprocess

d = open("WebTuna.wasm", "rb").read()

def uleb(b, i):
    r = 0; s = 0
    while True:
        x = b[i]; i += 1
        r |= (x & 0x7f) << s
        if not x & 0x80: break
        s += 7
    return r, i

sections = {}
i = 8
while i < len(d):
    sid = d[i]; i += 1
    size, i = uleb(d, i)
    sections.setdefault(sid, []).append((i, size))
    i += size

segs = []
for (base, size) in sections.get(11, []):
    j = base
    cnt, j = uleb(d, j)
    for _ in range(cnt):
        j += 2
        off, j = uleb(d, j)
        j += 1
        sz, j = uleb(d, j)
        segs.append((off, sz, j)); j += sz

MEM = bytearray(1 << 22)
for off, sz, base in segs:
    if off + sz <= len(MEM): MEM[off:off + sz] = d[base:base + sz]

def u32(a):
    if a is not None and 0 <= a and a + 4 <= len(MEM): return struct.unpack_from("<I", MEM, a)[0]
    return None

tbl2fn = {}
for (base, size) in sections.get(9, []):
    j = base
    cnt, j = uleb(d, j)
    off, j = uleb(d, j + 2); j += 1
    n, j = uleb(d, j)
    for k in range(n):
        idx, j = uleb(d, j)
        tbl2fn[off + k] = idx

mangled = re.compile(rb'N\d+[A-Za-z_][A-Za-z0-9_]*E')
names = {}
for off, sz, base in segs:
    blob = d[base:base + sz]
    for m in mangled.finditer(blob):
        e = m.end()
        if e < len(blob) and blob[e] == 0:
            names[off + m.start()] = m.group(0).decode()

DEM = {}
def demangle(s):
    if s not in DEM:
        DEM[s] = subprocess.run(["c++filt", s + "\n"], capture_output=True, text=True).stdout.strip() or s
    return DEM[s]

# value -> [field addresses]
val2fields = {}
for a in range(0, len(MEM) - 3, 4):
    v = u32(a)
    val2fields.setdefault(v, []).append(a)

# typeinfo objects: address X holds a name pointer; typeinfo base = X-4
ti2name = {}
for na, nm in names.items():
    for X in val2fields.get(na, []):
        ti2name[X - 4] = nm

# vtable: [offset_to_top(=0), typeinfo, methods...]  -> typeinfo slot at vt-8
vt2ti = {}
for vt in range(8, len(MEM) - 8, 4):
    if u32(vt - 8) == 0 and u32(vt - 4) in ti2name:
        vt2ti[vt] = ti2name[u32(vt - 4)]

res = {}
for vt, nm in vt2ti.items():
    slots = []
    p = vt
    while True:
        v = u32(p)
        if v is None or v not in tbl2fn: break
        slots.append(((p - vt) // 4, v, tbl2fn[v]))
        p += 4
        if len(slots) > 60: break
    if len(slots) >= 2:
        res[vt] = (nm, slots)

out = {}
for vt, (nm, slots) in sorted(res.items()):
    out[demangle(nm)] = {"vtable": vt, "methods": [{"offset": s[0], "table": s[1], "func": s[2]} for s in slots]}
json.dump(out, open("classes.json", "w"), indent=1)
json.dump({demangle(v): k for k, v in ti2name.items()}, open("typenames.json", "w"), indent=1)

print(f"typeinfo objects: {len(ti2name)}   validated vtables: {len(out)}\n")
print("=== Yousician::* classes (vtable + method func indices) ===")
for k in sorted(out):
    if "Yousician" in k:
        print(f"{k}\n    vtable@{out[k]['vtable']}  funcs={[m['func'] for m in out[k]['methods']]}")
print("\n=== all RTTI names ===")
for n in sorted(set(demangle(v) for v in ti2name.values())):
    print("  ", n)

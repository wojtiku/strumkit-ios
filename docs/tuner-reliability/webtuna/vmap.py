#!/usr/bin/env python3
import re, sys, json
d = open("WebTuna.wasm", "rb").read()
def uleb(b, i):
    r = 0; s = 0
    while True:
        x = b[i]; i += 1
        r |= (x & 0x7f) << s
        if not x & 0x80: break
        s += 7
    return r, i
i = 8
tbl2fn = {}
while i < len(d):
    sid = d[i]; i += 1
    size, i = uleb(d, i)
    if sid == 9:
        j = i
        cnt, j = uleb(d, j)
        off, j = uleb(d, j + 2); j += 1
        n, j = uleb(d, j)
        for k in range(n):
            idx, j = uleb(d, j)
            tbl2fn[off + k] = idx
    i += size
json.dump(tbl2fn, open("tbl2fn.json", "w"))

DC = open("WebTuna.dcmp", encoding="utf8", errors="surrogateescape").read().split("\n")
starts = []
for k, l in enumerate(DC):
    m = re.match(r'(?:export )?function (\w+)\(', l)
    if m:
        m2 = re.search(r'// func(\d+)\s*$', l)
        starts.append((m.group(1), int(m2.group(1)) if m2 else None, k))
starts.append((None, None, len(DC)))
byname = {n: (i, starts[k+1][2]) for k, (n, idx, i) in enumerate(starts[:-1])}
byidx = {idx: (n, i, starts[k+1][2]) for k, (n, idx, i) in enumerate(starts[:-1]) if idx is not None}

mode = sys.argv[1] if len(sys.argv) > 1 else "map"
if mode == "map":
    lo, hi = (int(x) for x in (sys.argv[2], sys.argv[3]))
    for t in range(lo, hi):
        f = tbl2fn.get(t)
        if f is None: continue
        n, s, e = byidx.get(f, (None, 0, 0))
        sig = DC[s].strip()[:200]
        print(f"table[{t}] -> func{f}  {n}")
elif mode == "sig":
    for t in [int(x) for x in sys.argv[2:]]:
        f = tbl2fn[t]
        n, s, e = byidx[f]
        print(f"--- table[{t}] = func{f} ({n}) lines {s}-{e} ---")
        print("\n".join(DC[s:min(e, s + 40)]))
        print()
elif mode == "fn":
    for f in [int(x) for x in sys.argv[2:]]:
        n, s, e = byidx[f]
        print(f"--- func{f} ({n}) lines {s}-{e} ---")
        print("\n".join(DC[s:e]))
        print()

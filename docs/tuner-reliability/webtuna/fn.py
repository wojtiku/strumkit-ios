#!/usr/bin/env python3
"""Extract a function (and optionally its callees) from WebTuna.dcmp."""
import re, sys, subprocess, json

DC = open("WebTuna.dcmp", encoding="utf8", errors="surrogateescape").read().split("\n")
starts = []
for i, l in enumerate(DC):
    m = re.match(r'(?:export )?function (\w+)\(', l)
    if m:
        idx = None
        m2 = re.search(r'// func(\d+)\s*$', l)
        if m2: idx = int(m2.group(1))
        starts.append((m.group(1), idx, i))
starts.append((None, None, len(DC)))
byname = {n: (i, starts[k+1][2]) for k, (n, idx, i) in enumerate(starts[:-1])}
byidx = {}
for k, (n, idx, i) in enumerate(starts[:-1]):
    if idx is not None: byidx[idx] = (n, i, starts[k+1][2])

def dump(name=None, idx=None, callees=0):
    if idx is not None:
        n, s, e = byidx[idx]; label = f"// func{idx} = {n}"
    else:
        s, e = byname[name]; label = f"// {name}"
    print("=" * 100)
    print(label, f"  lines {s}-{e} ({e-s})")
    print("=" * 100)
    print("\n".join(DC[s:e]))
    if callees:
        body = "\n".join(DC[s:e])
        called = set()
        for m in re.finditer(r'\b([a-z]_[A-Za-z0-9_]+)\(', body):
            called.add(m.group(1))
        for m in re.finditer(r'call_indirect\((\d+)', body):
            called.add("ind:" + m.group(1))
        for c in sorted(called):
            if c.startswith("ind:"):
                continue
            if c in byname:
                s2, e2 = byname[c]
                print(f"\n----- callee {c} -----")
                print("\n".join(DC[s2:e2]))
            else:
                print(f"\n----- callee {c}: NOT FOUND (import?) -----")

if __name__ == "__main__":
    a = sys.argv[1]
    cal = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    if a.isdigit():
        dump(idx=int(a), callees=cal)
    else:
        dump(name=a, callees=cal)

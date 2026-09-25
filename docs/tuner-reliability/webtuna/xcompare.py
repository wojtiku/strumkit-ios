#!/usr/bin/env python3
"""Diff StrumKit and WebTuna traces produced from identical coverage-matrix cells.

Usage: xcompare.py <xeng-trace.txt> <xweb-trace.txt> <xtruth.txt>

Two things are checked before anything is scored, because both failure modes
below produce a table that looks clean:

* **Label parity.** The two traces must cover the same cells, and that set must
  match the truth table. A cell that silently disappears from one side would
  otherwise shrink the comparison without changing its shape — a missing cell is
  worse than a failing one, so this exits non-zero and prints every label.
* **Signal parity.** Each SUMMARY line carries an FNV-1a checksum of the signal
  both sides generated for that cell. Equal checksums mean the two engines
  heard byte-identical audio; unequal ones mean the generators drifted and
  every number in the table is void, however plausible it looks.

The truth table is itself generated from `xcells.json`, which the Swift emitter
writes, so all three files descend from one matrix.

Exit codes: 0 compared, 2 parity failure, 1 misuse or a duplicated cell.
"""
import re
import sys

# 50 cents, mirroring CrossEngineComparisonTests.centsTolerance and
# CENTS_TOLERANCE in xeng.mjs. It is not applied here: these are the
# first/last values the two emitters already gated on, and re-deriving them
# from the per-frame lines would reintroduce a place for the two tolerances to
# disagree.
CENTS_TOLERANCE = 50.0


def parse(path, tag):
    """label -> key/value dict, from the `TAG-SUMMARY` lines of one trace."""
    cells = {}
    pattern = re.compile(r"^" + tag + r"-SUMMARY\|([^|]+)\|(.*)$")
    with open(path, encoding="utf8", errors="replace") as handle:
        for line in handle:
            m = pattern.match(line.strip())
            if not m:
                continue
            label = m.group(1)
            if label in cells:
                raise SystemExit(
                    f"FAIL: {label} has more than one {tag}-SUMMARY line in {path}. "
                    "A duplicated cell means one side is reporting two runs "
                    "under one label; the comparison would be undefined."
                )
            cells[label] = dict(
                p.split("=", 1) for p in m.group(2).split("|") if "=" in p
            )
    return cells


def load_truth(path):
    truth = {}
    with open(path, encoding="utf8") as handle:
        for line in handle:
            line = line.strip()
            if not line or "=" not in line:
                continue
            k, v = line.split("=", 1)
            truth[k] = float(v)
    return truth


def num(entry, key):
    """A summary field as a float, defaulting to -1 ('never heard')."""
    try:
        return float(entry.get(key, -1))
    except (TypeError, ValueError):
        return -1.0


def check_parity(truth, eng, web, eng_path, web_path, truth_path):
    """Print every label that does not appear on all three sides. Return True if clean."""
    truth_labels, eng_labels, web_labels = set(truth), set(eng), set(web)
    only_eng = sorted(eng_labels - web_labels)
    only_web = sorted(web_labels - eng_labels)
    missing_both = sorted(truth_labels - (eng_labels | web_labels))
    invented = sorted((eng_labels | web_labels) - truth_labels)

    print("Parity")
    print(f"  truth ({len(truth_labels):>3} cells)  {path_label(truth_path)}")
    print(f"  StrumKit ({len(eng_labels):>3} cells)  {path_label(eng_path)}")
    print(f"  WebTuna  ({len(web_labels):>3} cells)  {path_label(web_path)}")

    problems = [
        ("in the StrumKit trace but not the WebTuna trace", only_eng),
        ("in the WebTuna trace but not the StrumKit trace", only_web),
        ("in neither trace (present in the truth table)", missing_both),
        ("in a trace but not in the truth table", invented),
    ]
    bad = False
    for description, labels in problems:
        if not labels:
            continue
        bad = True
        print(f"  FAIL  {len(labels)} cell(s) {description}:")
        for label in labels:
            side = []
            if label in eng_labels:
                side.append("StrumKit")
            if label in web_labels:
                side.append("WebTuna")
            if label in truth_labels:
                side.append("truth")
            print(f"          {label}   [{', '.join(side)}]")

    if bad:
        print()
        print("  REFUSING TO SCORE. The table below would compare different")
        print("  subsets of the matrix on each side, which reads as a clean")
        print("  result while measuring nothing. Fix the traces first.")
        return False

    print(f"  OK     all {len(truth_labels)} labels present on all three sides")
    return True


def check_signals(eng, web):
    """FNV-1a of the signal each side generated, per cell. Return True if identical."""
    print()
    print("Signal parity (FNV-1a of the generated audio)")
    mismatches = []
    unchecked = []
    for label in sorted(set(eng) & set(web)):
        e, w = eng[label].get("sig"), web[label].get("sig")
        if e is None or w is None:
            unchecked.append(label)
        elif e != w:
            mismatches.append((label, e, w))
    if mismatches:
        print(f"  FAIL  {len(mismatches)} of {len(eng)} cells generated DIFFERENT audio:")
        for label, e, w in mismatches:
            print(f"          {label:<16} StrumKit {e}  WebTuna {w}")
        print()
        print("  REFUSING TO SCORE. Two different signals cannot be compared, and")
        print("  the table would look entirely normal. The generators in")
        print("  CoverageMatrix.signal and xeng.mjs have drifted apart.")
        return False
    if unchecked:
        print(f"  FAIL  {len(unchecked)} cell(s) carry no `sig` field on one or both sides;")
        print(f"        the parity check cannot run: {unchecked[:5]}")
        return False
    print(f"  OK     all {len(eng)} cells produced byte-identical audio on both sides")
    return True


def path_label(path):
    return path.rsplit("/", 1)[-1]


def main(eng_path, web_path, truth_path):
    truth = load_truth(truth_path)
    eng = parse(eng_path, "XENG")
    web = parse(web_path, "XWEB")

    if not eng or not web:
        print("FAIL: a trace is empty. The usual cause is xcells.json not having been")
        print("      written by the Swift test, which makes `node xeng.mjs` run over")
        print("      nothing at all.")
        return 2

    if not check_parity(truth, eng, web, eng_path, web_path, truth_path):
        return 2
    if not check_signals(eng, web):
        return 2

    hdr = (f"{'cell':<16}{'truth':>9} | {'SK first':>9}{'SK last':>9}{'trans':>6}"
           f" | {'WT first':>9}{'WT last':>9} | {'winner':>8}")
    print()
    print(hdr)
    print("-" * len(hdr))
    def fmt(v):
        return f"{v:9.3f}" if v > 0 else f"{'-':>9}"

    eng_wins = web_wins = 0
    heard_eng = heard_web = 0
    first_eng = []
    first_web = []
    for label in sorted(truth):
        e, w = eng.get(label, {}), web.get(label, {})
        ef, el = num(e, "first"), num(e, "last")
        wf, wl = num(w, "first"), num(w, "last")
        heard_e, heard_w = el > 0, wl > 0
        heard_eng += heard_e
        heard_web += heard_w
        if ef > 0:
            first_eng.append(ef)
        if wf > 0:
            first_web.append(wf)
        if heard_e and not heard_w:
            winner, eng_wins = "StrumKit", eng_wins + 1
        elif heard_w and not heard_e:
            winner, web_wins = "WebTuna", web_wins + 1
        else:
            winner = "tie" if heard_e else "neither"

        trans = e.get("transitions", "-")
        print(f"{label:<16}{truth[label]:9.2f} | {fmt(ef)}{fmt(el)}{str(trans):>6}"
              f" | {fmt(wf)}{fmt(wl)} | {winner:>8}")

    def median(xs):
        s = sorted(xs)
        return s[len(s) // 2] if len(s) % 2 else (s[len(s) // 2 - 1] + s[len(s) // 2]) / 2

    n = len(truth)
    print()
    print(f"StrumKit heard {heard_eng}/{n} cells, WebTuna {heard_web}/{n}.")
    print(f"StrumKit heard {eng_wins} cells WebTuna missed; "
          f"WebTuna heard {web_wins} cells StrumKit missed.")
    print(f"Median time to first correct reading: StrumKit {median(first_eng):.3f} s "
          f"(n={len(first_eng)}), WebTuna {median(first_web):.3f} s (n={len(first_web)}).")
    print()
    print("`first`/`last` are seconds at which the engine's own reported frequency was")
    print(f"within {CENTS_TOLERANCE:.0f} cents of truth, or '-' for never. `trans` is")
    print("StrumKit's display-state transition count, the G1 number, shown for context.")
    print()
    print("Caveat on time-to-first-reading: WebTuna's ABI takes a fixed 4096-sample call")
    print("and its first two calls always return CanHearANote == false, so 0.279 s is a")
    print("floor imposed by the oracle, not a tuning advantage. Read it as 'not slower'.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2], sys.argv[3]))

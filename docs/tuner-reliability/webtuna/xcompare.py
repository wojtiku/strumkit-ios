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
writes, so all three files descend from one matrix. Its frequency column is a
human-readable convenience, **not** a third check on `noteHz`: both emitters
gate on the manifest's own `noteHz`, and nothing here re-derives a verdict from
it. It exists so a human reading the table does not have to open the JSON.

A third outcome is checked after the table, and it is the one G2 exists to catch:
**if neither engine heard anything at all, the run is not a result.** That exits
non-zero. A zero-detect run must produce a complete, readable, deliberately
alarming report — never a traceback, because a crash here would take the
*other* engine's numbers with it and hide the failure behind a stack trace.

Exit codes: 0 compared, 2 parity failure or nobody heard anything,
3 an input file is missing or unreadable, 1 misuse or a duplicated cell.
"""
import os
import re
import subprocess
import sys
import tempfile

# 50 cents, mirroring CrossEngineComparisonTests.centsTolerance and
# CENTS_TOLERANCE in xeng.mjs. It is not applied here: these are the
# first/last values the two emitters already gated on, and re-deriving them
# from the per-frame lines would reintroduce a place for the two tolerances to
# disagree.
CENTS_TOLERANCE = 50.0

# The one canonical way to regenerate `xtruth.txt`, printed verbatim when the
# truth table is missing. Three things this has to be, and was not:
#
#   * Runnable on the Python that is actually here. An f-string that indexes
#     `c['label']` inside single quotes is valid only on 3.12+; on 3.9 it is a
#     SyntaxError. `+` and `str()` are version-agnostic and produce identical
#     output for both ints and floats, so the data block is unchanged.
#   * Self-sufficient. It builds the file from `xtruth-header.txt` and
#     `xcells.json` and never reads `xtruth.txt`, so the remedy printed for
#     "xtruth.txt is missing" is actually runnable in that situation. The
#     previous version copied the header out of the file it was repairing.
#   * Idempotent. A pure function of two committed inputs, so running it on its
#     own output is a no-op. The previous version appended to what it read and
#     produced 104 lines instead of 68.
#
# The copy in ../README.md must stay in step; `self_check` below re-pastes this
# string, executes it with `xtruth.txt` absent, and requires byte-identity.
TRUTH_TABLE_RECIPE = (
    "cat xtruth-header.txt > xtruth.txt.new && "
    'python3 -c "import json;'
    "[print(c['label'] + '=' + str(c['noteHz'])) "
    "for c in json.load(open('xcells.json'))]\" >> xtruth.txt.new && "
    "mv xtruth.txt.new xtruth.txt"
)


def median(xs):
    """Median of a possibly-empty list, or None. None prints as `n/a`.

    An empty list is a real outcome, not an error: it is what a zero-detect run
    produces for one engine. Returning None and letting the caller render `n/a`
    keeps the other engine's median on the same line, which is the whole point —
    "StrumKit heard nothing, WebTuna's median was 0.279 s" is the report the
    failure deserves.
    """
    if not xs:
        return None
    s = sorted(xs)
    if len(s) % 2:
        return s[len(s) // 2]
    return (s[len(s) // 2 - 1] + s[len(s) // 2]) / 2


def fmt_median(x):
    return "n/a" if x is None else f"{x:.3f} s"


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
            # `#` is a comment. Not `=`-detection alone: a future note about a
            # field like `idx=-1` would otherwise be parsed as a cell called
            # "idx" with the value -1.
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            truth[k] = float(v)
    return truth


def require_file(path, what, produced_by):
    """Exit with a named cause rather than an unhandled FileNotFoundError.

    A missing file and an empty file are different failures with different
    fixes, and only the empty one used to be explained.
    """
    if not os.path.isfile(path):
        print(f"FAIL: the {what} file is missing: {path}")
        print(f"      Produced by: {produced_by}")
        print("      Nothing was compared. An absent input and a present-but-empty")
        print("      input are different faults; this is the absent one.")
        raise SystemExit(3)


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
    require_file(truth_path, "truth table", TRUTH_TABLE_RECIPE)
    require_file(eng_path, "StrumKit trace",
                 "xcodebuild test -only-testing:StrumKitTests/CrossEngineComparisonTests "
                 "| grep -E '^(XENG|XENG-SUMMARY)'")
    require_file(web_path, "WebTuna trace", "node xeng.mjs > xweb-trace.txt")

    truth = load_truth(truth_path)
    eng = parse(eng_path, "XENG")
    web = parse(web_path, "XWEB")

    if not eng or not web:
        empty_side = "both" if not eng and not web else ("StrumKit" if not eng else "WebTuna")
        print(f"FAIL: the {empty_side} trace is present but contains no SUMMARY lines.")
        print("      The usual cause is xcells.json not having been written by the")
        print("      Swift test, which makes `node xeng.mjs` run over nothing at all.")
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

    n = len(truth)
    med_eng, med_web = median(first_eng), median(first_web)
    print()
    print(f"StrumKit heard {heard_eng}/{n} cells, WebTuna {heard_web}/{n}.")
    print(f"StrumKit heard {eng_wins} cells WebTuna missed; "
          f"WebTuna heard {web_wins} cells StrumKit missed.")
    print(f"Median time to first correct reading: StrumKit {fmt_median(med_eng)} "
          f"(n={len(first_eng)}), WebTuna {fmt_median(med_web)} (n={len(first_web)}).")
    print()
    print("`first`/`last` are seconds at which the engine's own reported frequency was")
    print(f"within {CENTS_TOLERANCE:.0f} cents of truth, or '-' for never. `trans` is")
    print("StrumKit's display-state transition count, the G1 number, shown for context.")
    print()
    print("Caveat on time-to-first-reading: WebTuna's ABI takes a fixed 4096-sample call")
    print("and its first two calls always return CanHearANote == false, so 0.279 s is a")
    print("floor imposed by the oracle, not a tuning advantage. Read it as 'not slower'.")

    # The G2 outcome this whole file exists to detect. Not a crash, not a warning
    # in a log nobody reads: a loud, non-zero, complete report.
    if heard_eng == 0 and heard_web == 0:
        print()
        print("!" * 72)
        print("FAIL: NEITHER ENGINE HEARD ANYTHING. 0/40 and 0/40.")
        print("!" * 72)
        print("  This is not a measurement. G2 exists to catch exactly this, and a")
        print("  clean-looking table above it is the failure mode this check is for.")
        print("  Usual causes, in order of likelihood:")
        print("    - the audio never reached either engine (trace files from a")
        print("      different run than the manifest, or an empty signal path)")
        print("    - the cells' truth frequencies no longer match what the engines")
        print("      were fed; check `noteHz` in xcells.json against the presets")
        print("    - a regression that stops both pipelines naming a note at all")
        print("  Exiting non-zero. Do not record this run as a baseline.")
        return 2
    if heard_eng == 0 or heard_web == 0:
        side = "StrumKit" if heard_eng == 0 else "WebTuna"
        print()
        print(f"WARNING: {side} heard 0/{n} cells. The other engine's numbers are")
        print("         still reported above and are still valid, but a total")
        print("         detection failure is almost always a broken run rather")
        print("         than a tuning-quality result. Check the trace before using it.")
    return 0


def self_check():
    """Exercise the failure paths this script must survive, in a temp directory.

    Written because the zero-detect path is the one G2 exists to detect, and it
    used to be the one path that crashed. A guard that has never been run is a
    guess. Each case below is a real regression this file has shipped with.

    Run: `python3 xcompare.py --self-check`
    """
    import io
    import contextlib

    cells = [("c1", 110.0), ("c2", 146.83)]
    failures = []

    def write(dirpath, name, text):
        path = os.path.join(dirpath, name)
        with open(path, "w", encoding="utf8") as handle:
            handle.write(text)
        return path

    def summary(tag, label, first, last, sig="deadbeef", extra=""):
        return (f"{tag}-SUMMARY|{label}|truth=0|first={first}|last={last}"
                f"|transitions=0{extra}|sig={sig}\n")

    def run(eng, web, truth):
        """Invoke main() in-process and capture both its output and its fate.

        Any non-SystemExit exception is converted into a recorded failure rather
        than being allowed to escape: a self-check that dies with the same
        traceback it is meant to detect reports nothing useful.
        """
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            try:
                code = main(eng, web, truth)
            except SystemExit as exc:
                code = exc.code
            except Exception as exc:                      # noqa: BLE001
                return "raised " + type(exc).__name__, buf.getvalue()
        return code, buf.getvalue()

    with tempfile.TemporaryDirectory() as tmp:
        # 1. A normal comparison must still work and exit 0.
        e = write(tmp, "ok-eng.txt",
                  "".join(summary("XENG", l, 0.05, 2.9) for l, _ in cells))
        w = write(tmp, "ok-web.txt",
                  "".join(summary("XWEB", l, 0.3, 2.9) for l, _ in cells))
        t = write(tmp, "ok-truth.txt", "".join(f"{l}={f}\n" for l, f in cells))
        code, out = run(e, w, t)
        if code != 0 or "StrumKit heard 2/2" not in out:
            failures.append(f"baseline run: expected exit 0 and 2/2, got {code}: {out[-200:]!r}")
        if "n/a" in out:
            failures.append("baseline run: reported n/a for a median it had data for")

        # 2. The regression: every cell a miss. Must be a complete, alarming,
        #    non-zero report with n/a - never an IndexError.
        me = write(tmp, "miss-eng.txt",
                   "".join(summary("XENG", l, -1, -1) for l, _ in cells))
        mw = write(tmp, "miss-web.txt",
                   "".join(summary("XWEB", l, -1, -1) for l, _ in cells))
        code, out = run(me, mw, t)
        if "Traceback" in out or "IndexError" in out:
            failures.append("all-miss: crashed instead of reporting")
        if code == 0:
            failures.append("all-miss: exited 0; a silent pass is worse than a crash")
        if "NEITHER ENGINE HEARD ANYTHING" not in out:
            failures.append("all-miss: did not say nobody heard anything")
        if out.count("n/a") != 2:
            failures.append(f"all-miss: expected 2 n/a medians, got {out.count('n/a')}")
        if "StrumKit heard 0/2" not in out:
            failures.append("all-miss: lost the per-engine heard count")

        # 3. One engine silent, the other fine. The table and the surviving
        #    engine's median must both survive, with a warning.
        oe = write(tmp, "one-eng.txt",
                   "".join(summary("XENG", l, -1, -1) for l, _ in cells))
        code, out = run(oe, w, t)
        if "Traceback" in out:
            failures.append("one-silent: crashed")
        if "WARNING: StrumKit heard 0/2" not in out:
            failures.append("one-silent: did not warn")
        if "WebTuna 0.300 s" not in out:
            failures.append("one-silent: lost WebTuna's median, the whole point of the guard")

        # 4. A missing file must name its cause, not raise FileNotFoundError.
        code, out = run(os.path.join(tmp, "absent.txt"), w, t)
        if "Traceback" in out or "FileNotFoundError" in out:
            failures.append("missing input: unhandled FileNotFoundError")
        if code == 0:
            failures.append("missing input: exited 0")
        if "missing" not in out or "Produced by" not in out:
            failures.append("missing input: did not name the cause or how to produce it")

        # 5. An empty file is a different fault from an absent one, and says so.
        empty = write(tmp, "empty.txt", "")
        code, out = run(empty, w, t)
        if "no SUMMARY lines" not in out:
            failures.append("empty input: did not distinguish itself from a missing file")
        if code == 0:
            failures.append("empty input: exited 0")

        # 6. A `#` comment in the truth table must not become a cell.
        commented = write(tmp, "comment-truth.txt",
                          "# idx=-1 is not a cell\n" + "".join(f"{l}={f}\n" for l, f in cells))
        code, out = run(e, w, commented)
        if code != 0:
            failures.append(f"commented truth table: expected exit 0, got {code}")

        # 7. The remedy the missing-file error prints must be runnable, on the
        #    Python that is actually here, and must round-trip the file rather
        #    than append to it. Both halves of N-3: the old f-string remedy was a
        #    SyntaxError on 3.9, and the old `sed -n '1,/^$/p'` header copy had no
        #    terminating blank line to stop at, so it copied the whole file.
        import re as _re
        payload = _re.search(r'python3 -c "(.*?)"', TRUTH_TABLE_RECIPE)
        if payload is None:
            failures.append("TRUTH_TABLE_RECIPE has no extractable python payload")
        else:
            program = payload.group(1).replace('\\"', '"')
            try:
                compile(program, "<remedy>", "exec")
            except SyntaxError as exc:
                failures.append(f"TRUTH_TABLE_RECIPE is not runnable here: {exc.msg}")

        # Round-trip: build the two committed inputs, leave `xtruth.txt` ABSENT,
        # run the real recipe in a scratch dir, and require exactly the expected
        # bytes. Absent is the point: this is the situation the remedy is printed
        # for, and the previous version could not run there at all.
        scratch = os.path.join(tmp, "scratch")
        os.makedirs(scratch, exist_ok=True)
        with open(os.path.join(scratch, "xcells.json"), "w", encoding="utf8") as h:
            h.write('[{"label": "c1", "noteHz": 110}, {"label": "c2", "noteHz": 82.4069}]')
        with open(os.path.join(scratch, "xtruth-header.txt"), "w", encoding="utf8") as h:
            h.write("# header\n#\n# generated\n")
        expected = "# header\n#\n# generated\nc1=110\nc2=82.4069\n"
        proc = subprocess.run(["sh", "-c", TRUTH_TABLE_RECIPE], cwd=scratch,
                              capture_output=True, text=True)
        if proc.returncode != 0:
            failures.append(f"TRUTH_TABLE_RECIPE exited {proc.returncode}: {proc.stderr.strip()[:200]}")
        elif not os.path.exists(os.path.join(scratch, "xtruth.txt")):
            failures.append("TRUTH_TABLE_RECIPE did not produce xtruth.txt from an absent start")
        else:
            with open(os.path.join(scratch, "xtruth.txt"), encoding="utf8") as h:
                after = h.read()
            if after != expected:
                failures.append(f"TRUTH_TABLE_RECIPE produced {after!r}, expected {expected!r}")
            # And it must be a no-op on its own output.
            proc2 = subprocess.run(["sh", "-c", TRUTH_TABLE_RECIPE], cwd=scratch,
                                   capture_output=True, text=True)
            with open(os.path.join(scratch, "xtruth.txt"), encoding="utf8") as h:
                again = h.read()
            if proc2.returncode != 0 or again != expected:
                failures.append("TRUTH_TABLE_RECIPE is not idempotent")
            if again.count("c1=110") != 1:
                failures.append("TRUTH_TABLE_RECIPE duplicated the data block")

    if failures:
        print(f"SELF-CHECK FAILED ({len(failures)}):")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("SELF-CHECK PASSED: 7 cases, including the all-miss zero-detect path "
          "and an executed copy of the missing-file remedy.")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-check"]:
        sys.exit(self_check())
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2], sys.argv[3]))

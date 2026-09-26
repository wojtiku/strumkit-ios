# WebTuna tooling

Reverse-engineering harness for `WebTuna.wasm` (GuitarTuna's web-tuner pitch engine,
Yousician). See [`../WEBTUNA.md`](../WEBTUNA.md) for the findings.

## Prerequisites

```bash
brew install wabt                    # wasm-objdump, wasm2wat (note: no wasm-decompile)

# wasm-decompile was deleted in wabt 1.0.42 and is NOT in the Homebrew bottle.
# 1.0.41 is the last release that ships it:
git clone --depth 1 --branch 1.0.41 https://github.com/WebAssembly/wabt
cmake -S wabt -B wabt/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF
ninja -C wabt/build wasm-decompile
./wabt/build/wasm-decompile WebTuna.wasm -o WebTuna.dcmp
```

Put `WebTuna.wasm` and `WebTuna.dcmp` in this directory.

## Python (static analysis)

| Script | What it does |
|---|---|
| `rtti.py` | Walks `__class_type_info` name pointers, validates vtables, writes `classes.json` — the whole `Yousician` class map. Needs a working `WebTuna.wasm` in cwd. |
| `itanium.py` | Minimal Itanium C++ demangler (macOS `c++filt` does not demangle `NSt3__2…` names here). |
| `vmap.py` | Maps function-table index ↔ function index; `map LO HI`, `sig T…`, `fn F…` subcommands. |
| `fn.py` | Extracts one function (and optionally its callees) from `WebTuna.dcmp`: `python3 fn.py f_gaa` or `python3 fn.py 708 1`. |

## Node (running the module)

`harness.mjs` instantiates the wasm with the **exact** import mapping from
`guitartuna.com/webtuna/WebTuna.js` and exposes `analyse(float32, stringIdx, sampleRate)`,
which returns the parsed JSON. `iso.mjs` wraps it in a fresh-instance factory.

> The engine is a **process-wide singleton with no reset**, so state leaks between cases.
> Always use `iso.mjs`'s `mk()` (one instance per test), not `harness.mjs` directly.

## Cross-engine comparison (Task 4, the G2 baseline)

`xeng.mjs` runs the Swift test target's coverage matrix through this oracle and emits
`XWEB|…` / `XWEB-SUMMARY|…` lines for the same labels `StrumKitTests/CrossEngineComparisonTests.swift`
prints as `XENG|…` / `XENG-SUMMARY|…`. `xcompare.py` diffs the two and prints the
head-to-head table recorded in [`../RESULTS.md`](../RESULTS.md) §11.

```bash
# 1. the Swift side writes docs/tuner-reliability/webtuna/xcells.json
#    -O is worth the separate derived-data path: 2.5 s against 276 s, identical output.
xcodebuild test -project StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./DerivedDataO \
  SWIFT_OPTIMIZATION_LEVEL=-O \
  -only-testing:StrumKitTests/CrossEngineComparisonTests 2>&1 \
  | grep -E '^(XENG|XENG-SUMMARY)' > /tmp/xeng-trace.txt

# 2. this side. Run from THIS directory: iso.mjs reads ./WebTuna.wasm from the cwd.
curl -o WebTuna.wasm https://guitartuna.com/webtuna/WebTuna.wasm
node xeng.mjs > xweb-trace.txt

# 3. score
python3 xcompare.py /tmp/xeng-trace.txt xweb-trace.txt xtruth.txt
```

`xtruth.txt` is generated from two committed inputs, `xtruth-header.txt` (the prose) and
`xcells.json` (the data), so the label set cannot drift. Its header documents what it is
and is not: a label set plus a human-readable frequency column, **not** a third independent
check on `noteHz` — both emitters gate on the manifest's own value. It is load-bearing as
the third leg of the label-parity check. Regenerate rather than hand-editing:

```bash
cat xtruth-header.txt > xtruth.txt.new && python3 -c "import json;[print(c['label'] + '=' + str(c['noteHz'])) for c in json.load(open('xcells.json'))]" >> xtruth.txt.new && mv xtruth.txt.new xtruth.txt
```

This is character-for-character the string `xcompare.py` prints as the remedy when
`xtruth.txt` is missing, so the copy here and the copy in the error message cannot
disagree — `xcompare.py --self-check` runs it with `xtruth.txt` **absent** and requires
byte-identity plus idempotence. Two details are load-bearing:

- The Python is `print(c['label'] + '=' + str(c['noteHz']))`, **not** an f-string indexing
  `c['label']` inside single quotes. That form is valid only on Python 3.12+; on the 3.9
  that is otherwise here it is a `SyntaxError`, which is what the error message used to
  print. Both produce identical output.
- The three integer-valued cells (`str-g1`, `str-u3`, `poly-A2+E4`) print as `110` and
  `440`, not `110.0` and `440.0`, because the manifest holds JSON integers for exactly
  those three. A previous hand-edited copy wrote `110.0`/`440.0`, which is why the file is
  now generated and never typed.

Two guards make a drift loud instead of silent, and `xcompare.py` exits 2 on either:

- **Label parity.** The two traces and the truth table must carry the *same* 40 labels. The
  cell list is emitted from Swift rather than hand-maintained for exactly this reason.
- **A zero-detect run.** If neither engine heard anything, the run is not a result: the
  table still prints in full, both medians print `n/a`, and the script exits non-zero with
  a loud block. This is the outcome G2 exists to catch, so it must never be a silent pass
  and must never be a traceback.
- **A missing or empty input file.** Named as its own fault, with the command that
  produces it.

`xcompare.py --self-check` exercises all of the above in a temp directory — including the
zero-detect path that used to crash on `median([])` — and exits non-zero if any guard is
removed:

```bash
python3 xcompare.py --self-check
```
- **Signal parity.** Every SUMMARY line carries `sig=`, an FNV-1a of the generated audio.
  Identical checksums mean both engines received byte-identical samples; a mismatch means
  `CoverageMatrix.signal` and `buildSignal` have drifted and every number downstream is void.

`WebTuna.wasm` and `WebTuna.dcmp` are Yousician's IP and are gitignored. `xeng-trace.txt` /
`xweb-trace.txt` are run products and are also ignored; regenerate them to re-score.

**Polyphony is synthesised:** `xcells.json` carries `extraFrequencies` per cell and
`buildSignal` mixes each one in as a bare sine at `EXTRA_VOICE_WEIGHT` (mirroring
`CoverageMatrix.extraVoiceWeight`; the two must match or the `sig=` checksums diverge).
The four `poly-` cells are genuinely two-voiced on both sides. This was broken once: the
frequency lived only on `Cell.extraStrings` and never reached the audio, so every poly
cell rendered as a lone note and the head-to-head reported WebTuna hearing all 40
including "E2+F#2, the pair that defeats WebTuna". `polyCellsArePolyphonic` in
`StrumKitTests/CoverageMatrixTests.swift` is what catches that now. See RESULTS.md §11.

```bash
node suite3.mjs   # accuracy / harmonic / noise / sample-rate characterisation
node suite4.mjs   # note gate, DC, latency, InTuneRatio vs detune, PossibleWrongStringId
node state2.mjs   # live engine state dump — this is where all the constants came from
node window.mjs   # locate the Ooura_FFT object in the live heap; verify the window function
node tables3.mjs  # dump + verify the 56-band filterbank tables
node frames.mjs   # prove frames-per-call and the InTuneRatio counter cadence
```

## Real recording: `realfile.mjs` + `seg_summary.py`

`realfile.mjs` runs a real recording through the WebTuna oracle and prints a segment
table. `seg_summary.py` does the same for a StrumKit replay trace of the same file, so
the two tables are read against each other rather than compared by eye:

```bash
# 1. WebTuna side. Run from THIS directory: iso.mjs reads ./WebTuna.wasm from the cwd.
node realfile.mjs ../../StrumKitTests/Fixtures/all-4-with-noise.wav

# 2. StrumKit side. Three configurations; -O so the scalar YIN loop is not the bottleneck.
xcodebuild test -project ../../StrumKit.xcodeproj -scheme StrumKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ../../DerivedDataO \
  SWIFT_OPTIMIZATION_LEVEL=-O \
  -only-testing:StrumKitTests/RealStrumMeasurementTests 2>&1 \
  | grep -E '^SEG\|' > /tmp/strumkit-real.txt

# 3. the same segmentation and steadiness statistics over the StrumKit trace
python3 seg_summary.py /tmp/strumkit-real.txt --json /tmp/seg.json
```

`seg_summary.py`'s docstring is the specification of the shared method: a gap over 0.4 s
starts a new segment, a frame is "heard" when `CanHearANote && MeasuredPitchHz > 0` on
one side and `hz > 0 && state != "none"` on the other, steadiness is the p5–p95 cents
spread, and a segment that changes string mid-segment is flagged. It also names the two
places it deliberately differs, both forced by the inputs:

- **Target reference.** `realfile.mjs` uses the *first* string the segment reported, which
  is why its segment 5 prints NaN. `seg_summary.py` uses the segment's *modal* target
  frequency and prints the number of distinct targets instead of a NaN, so a segment that
  changed string is counted rather than hidden.
- **Display vs estimator.** StrumKit's `hz` is a *displayed* frequency, because a held
  reading repeats the last fresh value; WebTuna has no such distinction, since every call
  is a fresh measurement. So the script splits the per-frame DSP estimate into pure YIN
  (`rec=0`) and spectral-recovery substitutions (`rec=1`) and reports both.

Measured result: [`real-strum-measurement.md`](../../../.superpowers/sdd/2026-09-25-detection-layer-phases-0-3/real-strum-measurement.md).

## Findings cheat-sheet

* ABI: `analyseBuffer` is **table[7] → func708**, `(tableIdx, ptr, n, stringIdx, sampleRate) -> void`
* Window: `0.54 − 0.46·cos(2πn/4095)`, verified to 3e-8 against the live buffer
* 4096 real → 8192 complex Ooura FFT, hop 2048, **2 frames per 4096-sample call**
* Filterbank: 56 bands, `T(off)[k] = (10^(0.046804·max(0, 2.318973+0.5k+off)) − 1)·228.937714`
* Candidate grid: MIDI 26 + k/15 (6.67 ¢), 675 entries
* A4 = 440 exactly; string index 0 = highest string
* `InTuneRatio` = counter/15, +1 per call → 1.11 s to cross the site's 0.9 gate
* Domain guard: `checkDomain()` requires `guitartuna` / `yousician` / `localhost` in the URL


## YIN vs. salience reference measurement

`yinvsalience.mjs` answers the question the redesign spec turns on: is YIN actually weak on
weak fundamentals? It runs a reference YIN at StrumKit's own parameters (16 kHz, 1536-sample
window, lags 14–320, CMNDF threshold 0.15, StrumKit's own fundamental-energy gate applied)
against the WebTuna oracle, sweeping fundamental strength × SNR on the low E.

```bash
cp WebTuna.wasm . && node yinvsalience.mjs
```

Result: YIN reports the correct f0 with zero octave errors down to a fundamental carrying
0.00 % of the energy, and is rejected by `fundamentalMinEnergyRatio` in 6/6 of those cases.
WebTuna's only measured advantage is at 0 dB SNR. See
[`../../superpowers/specs/2026-09-25-tuner-detection-layer-design.md`](../../superpowers/specs/2026-09-25-tuner-detection-layer-design.md) §2.1.

Caveat recorded in the spec: these signals are perfectly harmonic. Real strings are
stretched by `fₙ = n·f₀·√(1+Bn²)`, and that axis is unmeasured here — it is an explicit
phase-0 item.

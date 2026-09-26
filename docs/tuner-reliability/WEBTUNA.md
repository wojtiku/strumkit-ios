# WebTuna — GuitarTuna web tuner's WebAssembly pitch engine, fully reverse-engineered

Scope: `WebTuna.wasm` (the module behind `guitartuna.com/online-guitar-tuner`) plus the
JavaScript that drives it. No StrumKit code is referenced here; comparison is a later step.

---

## 0. Provenance

| Item | Value |
|---|---|
| Module name | `WebTuna.wasm` |
| SHA-256 | `14ec8582a5cd1becfc8597fbc8bec75d2361f57522046ffdb0fbafc9394508bd` |
| Size | 296 937 bytes |
| Served from | `https://guitartuna.com/webtuna/WebTuna.wasm` (byte-identical to the local copy) |
| Glue | `https://guitartuna.com/webtuna/WebTuna.js` (Emscripten, minified) |
| Worklet | `https://guitartuna.com/tuner-processor.js` |
| Toolchain | Emscripten + clang, libc++ (Itanium RTTI), C++ |
| Vendor string in the binary | `This is a product of Yousician Ltd.` |
| wasm features used | MVP + `sign-extension` + `bulk-memory` (`memory.copy`, `memory.fill`) + multi-value + DataCount. **No SIMD, no threads, no reference types.** |
| Functions | 739 defined, 29 imported, 451-entry function table |
| Memory | 258 pages initial (16.5 MB), max 32 768 pages (2 GB) |
| Build | fully stripped: no `name` section, no `producers`, exports renamed to `D E F G H I J` |

`wasm-validate` (wabt 1.0.42) passes. Symbol names are only recoverable from **RTTI**, which
was left in. That RTTI is what gave away the whole class design (§2.4).

### The tools that actually mattered

`wasm-objdump`, `wasm2wat` and `wasm-interp` from wabt only got me started. The two things
that unlocked it were:

1. **`wasm-decompile` built from wabt 1.0.41** — the tool was deleted in wabt 1.0.42 and is
   not in the Homebrew bottle (which ships only 12 tools). Building 1.0.41 from source took
   two minutes and produced 39 275 lines of C-like output that is the readable form of this
   module. `https://v8.dev/blog/wasm-decompile` describes the same tool; the gotcha is that
   you need a version that still has it.
2. **Running the module under Node with the real glue's import table.** The wasm exports no
   pitch function, so decompilation alone could not tell you the entry point. Stubbing the 29
   imports exactly as `WebTuna.js` does, and logging the `__embind_register_function` calls
   in `__wasm_call_ctors`, revealed the API immediately (§2). From there I could call the
   detector on synthetic audio and treat it as an oracle, which turned guesswork into
   measurement.

`wasmkit/diswasm` and `wwwg/wasmdec` were not needed; `wasm-decompile` + the Elem section
(function-table layout) was enough.

---

## 1. How the site drives the module

### 1.1 Audio path

`/tuner-processor.js` is a plain `AudioWorkletProcessor` with no DSP in it:

```js
this.buffer = new Float32Array(4096);   // hard-coded
// accumulate render-quantum chunks, post 4096 at a time, no overlap, no windowing
```

So the engine is fed **exactly 4096 non-overlapping samples per call**, at whatever rate the
AudioContext runs (10.8 calls/s at 44.1 kHz, 11.7 at 48 kHz). No `getFloatTimeDomainData`
smoothing, no channel mixing, no AGC, no noise gate, no resampling.

The comment in the worklet states the reason: *"4096 … Matches the expected input size of
our tuning library."* That is a hard contract — feed it a different size and the internal
framing changes (§3.2).

### 1.2 Bootstrapping

An inline `<script id="webtuna-init">` runs before the lazy-loaded glue:

```js
window.ARRAY_SIZE = 4096;
window.Module = { onRuntimeInitialized: () => {
  data      = new Float32Array(4096);
  dataPtr   = Module._malloc(data.length * 4);
  dataHeap  = new Uint8Array(Module.HEAPU8.buffer, dataPtr, nDataBytes);
  analyseBuffer = Module.analyseBuffer;     // set by embind, not by assignWasmExports
  window.WebTuna = { data, dataHeap, analyseBuffer };
}};
```

`analyseBuffer` and `setTuning` are **embind** functions, which is why they are absent from
the wasm export list — embind attaches them to `Module` at run time.

Per audio callback:

```js
data.set(inputBuffer.getChannelData(0));
dataHeap.set(new Uint8Array(data.buffer));                       // re-validate after any grow
const json = analyseBuffer(dataHeap.byteOffset, data.length, stringIdx, sampleRate);
const r = JSON.parse(json);
```

The `dataHeap.set(...)` on every frame is a defensive re-derivation of the view after
`_emscripten_resize_heap` can detach the old `ArrayBuffer`.

### 1.3 The `stringIdx` argument

| value | meaning |
|---|---|
| `>= 0` | a **specific** string; the site sends `numStrings-1-uiIndex` (indices are reversed) |
| `-1` | **auto** (guitar, auto mode) |
| `-2` | **chromatic** (the "Online tuner" page, and every non-guitar instrument) |
| `< -2` | rejected, logs `Tuner mode not supported` |

The wasm's internal string order is **highest string first**: for a 6-string guitar,
`0 = E4 (329.63)`, `1 = B3 (246.94)`, `2 = G3 (196.00)`, `3 = D3 (146.83)`, `4 = A2 (110.00)`,
`5 = E2 (82.41)`. The UI lists strings low→high, hence the flip.

### 1.4 Output JSON (9 keys, alphabetically ordered by nlohmann/json)

```json
{
  "CanHearANote": true,          // bool   — per-frame note gate
  "CurrentString": 5,            // int    — wasm string index, or -1
  "InTuneRatio": 0.933,          // double — confidence, 0..1
  "Info": "This is a product of Yousician Ltd.",
  "MeasuredPitchHz": 83,         // double — floor()ed to whole Hz!
  "MeasuredPitchMidi": 40,       // int    — round(12*log2(f/440)+69), clamped [-48,175]
  "MicRms": 0.2075,              // double — input level meter
  "PossibleWrongStringId": -1,   // int    — "you probably meant this string"
  "TuningErrorCents": 3          // double — floor()ed to whole cents, vs the target
}
```

`MeasuredPitchHz` and `TuningErrorCents` are both `floor()`ed on the way out. This is a real
precision loss in the wire format: at E2 one Hz is 21 cents, so the reported Hz has ±21 ¢ of
quantisation. The reported *cents* come from the unrounded internal frequency, so they stay
accurate — the two fields disagree, and the site only uses the MIDI/cents pair.

### 1.5 Frontend behaviour that is part of the "algorithm"

These are in JS, not wasm, but they shape what the user experiences:

* **1-second hold.** If `CanHearANote` is false the site freezes the last good state for
  1000 ms before declaring "no note" (`if (0 === M.current && (M.current = e + 1e3), e < M.current) return;`).
* **In-tune test is `InTuneRatio > 0.9`.**
* **Needle:** `translateX(clamp(round(cents)/16, -12.5, 12.5) em)` → ±200 cents full scale,
  `cents >= 0` renders "Tune down".
* **Non-guitar / chromatic pages override the wasm's answer**: they pick the nearest string
  by MIDI, recompute `TuningErrorCents += 100*(measuredMidi - targetMidi)`, and **zero
  `InTuneRatio` unless the deviation is exactly 0**. So on those pages the green tick
  requires an exact equal-tempered note.
* **Per-string "tuned" latch** + a one-shot `tunerBlinkSound.mp3`.
* An 8-second timeout shows *"Looks like your browser doesn't support our interactive tuner"*
  if `window.WebTuna` never appears.

---

## 2. Binary archaeology

### 2.1 ABI

```
analyseBuffer  wasm:  (i32 tableIndex, i32 dataPtr, i32 numSamples, i32 stringIdx, f32 sampleRate) -> void
               thunk:  table[7]  -> call_indirect -> table[8] = func708
setTuning      wasm:  (i32 desc, i32 x, f32 y) -> void
               thunk:  table[9]  -> call_indirect -> table[10] = func706
malloc         table/export "H"          free  export "G"
getTypeName    export "F"                emscripten_timeout  export "J"
__wasm_call_ctors export "E"              memory "D"          table "I"
```

The Elem section maps the function table, which is how the entry points were located:
`table[6] = func495` (embind registration ctor), `table[7] = func709` → `table[8] = func708`
(`analyseBuffer`, 5 720 WAT lines), `table[9] = func707` → `table[10] = func706`
(`setTuning`). `func708` is also the only function that references all nine JSON key strings,
which confirms the identification.

Under the hood the declared C signature is
`void analyseBuffer(emscripten::memory_view<float> samples, int stringIdx, int, float sampleRate)`
— the trailing `int` is a defaulted argument the browser always passes as 0.

### 2.2 `setTuning` (unused by the web page, used by the mobile app)

Parses a JSON document keyed on `"instrument"` / `"tuning"`, erroring with
`Unknown instrument {}` / `Unknown instrument: {}` / `Tuner mode not supported`. It swaps the
string table, the per-string cent tolerances and the candidate-frequency range. The web page
never calls it, so the guitar page runs on the **compiled-in default tuning** (6-string
guitar, standard EADGBE, plus a hard-coded 35 → MIDI 64…40 table).

### 2.3 Anti-piracy guard

`analyseBuffer` begins with

```c
if (!checkDomain()) { console_error("Invalid Domain"); return; }   // "Invalid Domain"
```

where `checkDomain` is a JS import: `location.href.indexOf("guitartuna") !== -1 ||
…("yousician") !== -1 || …("localhost") !== -1`. Off-domain it silently returns a stub
result. Reproducing the algorithm in a Node harness requires faking `window.location`.

### 2.4 RTTI → class map

Walking `__class_type_info` name pointers and validating vtables (`offset_to_top == 0`
followed by a typeinfo pointer) recovers the complete `Yousician` namespace. That is the
entire domain model:

| Class | Role |
|---|---|
| `Yousician::ArraySlice<T, Align>` | non-owning view, align ∈ {1,2,4,8,16} |
| `Yousician::OwnedArraySlice<T, Align>` : `OwnedArraySliceBase<T>` | owning buffer |
| `Yousician::FFTBase`, `FFTBase::FFTBuffer` | FFT abstraction |
| `Yousician::Ooura_FFT` : `FFTBase` | the only concrete FFT (6 virtuals) |
| `Yousician::v::VectorPrimitiveInterface` / `v::VectorPrimitiveFallback` | 47-method SIMD shim (scalar fallback here) |

Everything else — the tuner, the salience, the state machine — is **non-virtual, free
functions on a singleton**. The class names `SalienceBooster::ApplyBoost` and
`SalienceBooster::ApplyBoost: Array length mismatch (got {}, expected {})` are the only
surviving class-ish names, and they tell us a salience post-processing stage exists.

The `v::` methods are a portability layer (NEON on iOS/Android, this scalar fallback on
wasm). I decoded the ones that matter by reading their bodies: slot 6 = elementwise
multiply, 18 = fill, 19 = scale, 29 = pow, 31 = **sum of squares**, 32 = **max**, 36 = lower_bound.

---

## 3. The algorithm, stage by stage

Everything below is per *analysis frame* (§3.2), not per API call.

### 3.1 Frame geometry (derived from the live object)

| Quantity | Value |
|---|---|
| Real FFT size | **4096** |
| Complex FFT size (zero-padded) | **8192** (Ooura `nshift = 1`) |
| Hop | **2048** (50 % overlap) |
| Window | `w[n] = 0.54 − 0.46·cos(2πn/(N−1))`, n = 0…4095 — *verified against the live buffer to 3·10⁻⁸* |
| Input ring buffer | 4096 samples, written with a 2048 stride |
| Frames per 4096-sample API call | **2** |
| Frame rate @ 44.1 kHz | 21.53 /s (46.4 ms) |
| Analysed spectrum range | FFT bins **7 … 1136** = **37.7 Hz … 6115 Hz** @ 44.1 kHz |
| All magnitudes are `float32` | |

The symmetric (not periodic) 0.54/0.46 window is applied at 50 % overlap, and it is
near-perfectly COLA: the overlap sum measures **1.07965 … 1.08000** over the whole frame
(**0.03 % ripple**). Coherent gain 1.0000, power gain 0.3973. The constant 1.08 is absorbed by
the salience normalisation, so the window introduces no amplitude modulation.

Bin 7 as the low edge is why DC offsets up to ±2.0 cost nothing (verified) and a DC of 5.0
destroys detection — the DC lands in bins the filterbank never reads.

### 3.2 Framing

`analyseBuffer` walks the input one sample at a time into the ring buffer; whenever the
write cursor reaches 4096 it runs a frame and rewinds the cursor to 2048. A 4096-sample call
therefore yields 2 frames. The site never exploits the 50 % overlap — it just gets 2× the
frame rate for free.

### 3.3 56-band log filterbank (the `SalienceBooster` neighbourhood)

Three 56-entry tables are built lazily on first use (`f_rs`, guarded by a one-shot flag) from

```
T(off)[k] = ( 10^( 0.046804 · max(0, 2.318973 + 0.5·k + off) ) − 1 ) · 228.937714
           off ∈ { −1, 0, +1 } ,  k = 0…55
```

giving lower edge, centre and upper edge in **Hz**. `T_lo[k] = T_ctr[k−1]`,
`T_hi[k] = T_ctr[k+1]`, so:

* centres 65.00 Hz … 5464.5 Hz
* each band is a **triangle** from `T_ctr[k−1]` up to `T_ctr[k]` and back down to
  `T_ctr[k+1]`, i.e. two-band support, 2× overlap, linearly interpolated in *frequency*

> **Correction (found while porting this to Swift — see [`WEBTUNA_SWIFT.md`](WEBTUNA_SWIFT.md)).**
> An earlier revision of this section stated "ratio per band `10^(0.046804/2)` = **1.055377**
> → **91.4 ¢** per band" and "effective frequency resolution ≈ 183 ¢". Both are wrong:
> `10^(0.046804/2)` is the ratio of the *exponential* term only and drops the `− 1` that
> the formula subtracts, so it is not the ratio of consecutive entries. The subtraction
> matters most at small `k`, where `10^x` is closest to 1. The true ratios are **not**
> constant:
>
> | k | ratio | cents |
> |---|---|---|
> | 0 | 1.250361 | 386.8 |
> | 9 | 1.106378 | 175.0 |
> | 18 | 1.078560 | 130.9 |
> | 27 | 1.067665 | 113.4 |
> | 36 | 1.062342 | 104.7 |
> | 45 | 1.059462 | 100.0 |
> | 54 | 1.057817 | 97.3 |
>
> So the filterbank is 97 ¢ per band at the top and **387 ¢ at the bottom**, averaging about
> 110 ¢ — coarser than stated, and coarsest exactly where low strings live. The centre-table
> formula itself is correct and reproduces the documented endpoints exactly (65.00 Hz and
> 5464.4 Hz). `WebTunaPortTests.testFilterbankGeometry` now pins the true values so this
> cannot regress.

Because the filterbank is this coarse, it cannot by itself locate a pitch to better than
~100–390 ¢. The wasm's 0–3 ¢ accuracy (§4.1) must therefore come from a second, finer
refinement stage that the earlier revision of this document did not identify.

### 3.4 Salience / loudness compression

For each of the 56 bands (with a floor at `mean · 1e-4` to kill dead bands):

```
a[k] = ( sqrt( 2 · max(mag[k], floor) / nBins ) )^(1/3)      # ≈ x^(1/6) compressed
i[k] = mag[k] / a[k]                                       # ≈ x^(2/3)
```

Both arrays are kept: `a` is the compressed magnitude and `i` the residual used for
harmonic-structure tests. This is a 1/6-power compression plus a 2/3-power residual — the
classic "compress for level, keep a residual for structure" pairing.

### 3.5 Candidate grid

A frequency table is precomputed per call (`f_sk`):

```
f_k = 440 · 2^( (26 + k/15) / 12 ) ,  k = 0 … 674      # 675 entries
```

i.e. **MIDI 26 upward in 1/15-semitone steps = 6.67 cents resolution**, spanning 45
semitones. Measured live: entry 0 = 36.710 Hz = MIDI 26.00, entry 1 = 36.850 Hz = MIDI 26.07,
675 entries (read out of the live object as `k[7] = 45`, `k[8] = table`, `k[6] = 26`).
The 56-band spectrum is linearly resampled onto this grid.

**Caveat, stated honestly:** chromatic mode reports pitches well above MIDI 71 (494 Hz) — up
to an observed ceiling near 1320 Hz — so the 675-entry grid is clearly a *coarse* search that
is then refined, not the final resolution. The grid's real job is to bound the search to the
tuning's span in string mode, which is where the accuracy and the robustness come from.

### 3.6 Peak picking and stability

* Local maxima are found on the 56-band salience; the 20-bin neighbourhood around each
  candidate is examined and a parabolic/spread estimate is formed from
  `(prev−centre)`, `(next−centre)` — the code tests `|(ba−fa)·−0.5 / ((fa+ba)·0.5 − peak)| > 0.5`
  and falls back to the raw bin.
* A **harmonic-support test** guards each peak: `ca = mag[cand]/mag[nextHigherHarmonic] > 2.0`
  and `ca/prevMag > 0.4` and `ca > k[20] + prevMag` must all hold, else the candidate is
  rejected. A pitch is only promoted to `state = 1/2` if it is within **±350 cents** of the
  current pitch (and a "1" state is only re-entered while already flagged).
* The pitch is smoothed with a **0.75 / 0.25 exponential filter** (hysteresis), and there is
  a separate **7-entry ring buffer of recent pitch estimates** used to compute the
  mode/median before committing (measured: the write cursor `g[10]` cycles 0…6).
* A **stability counter** saturates at **17**; two derived booleans latch at **5**
  consecutive agreeing results (`k[68]`, `k[69]`, both read out as 5 live). Live state after
  settling: `g[28] = 17`.
* Per-string cent tolerances read out live: `7, 7, 10, 7, 7, 12`, plus hard-coded gates in the
  code: **350 ¢** (candidate must be near the current pitch), **70 ¢** (a second continuity
  test), and **10 ¢** for chromatic mode.

### 3.7 `InTuneRatio` — the confidence value

```
InTuneRatio = g[48] / g[47]        // g[47] = 15, fixed
```

`g[48]` counts agreeing analysis results, clamped to `[0, 15]`. Measured live: the
numerator increments **once per 4096-sample API call** (not once per FFT frame — the RMS
ring cursor proves 2 frames fire per call), so the ratio steps by exactly 1/15 per call:

```
call   0  1  2  3  4  5  6  7  8  9 10 11 12 13
g[48]  0  3  4  5  6  7  8  9 10 11 12 13 14 15
ratio  .0 .2 .3 .3 .4 .5 .5 .6 .7 .7 .8 .9 .93 1.0
```

Crossing the site's 0.9 threshold takes 12 further calls after the note is first heard, so
the wall time from *silence* to "in tune" is **3 + 12 = 15 calls ≈ 1.30 s at 44.1 kHz**
(1.18 s at 48 kHz). Measured on a steady tone: first note at 0.279 s, first
`InTuneRatio > 0.9` at 1.300 s. It resets to 0 the moment the frame-level in-tune test
fails.

The pitch vote that feeds it uses a **7-entry** ring buffer (`g[10]` cycles 0…6, one step
per call, measured) — i.e. a 652 ms median/mode window, not 7 FFT frames.

The frame-level test is purely cent-based: at E2 the ratio is 1.00 up to +12 ¢ and 0.00 from
+15 ¢, matching the ~12 ¢ per-string tolerance.

### 3.8 `MicRms`

```
MicRms = 128 · max( spectrumRMS over a 64-frame ring buffer )
spectrumRMS = sqrt( Σ spectrum² / nBins )
```

A **peak-hold over 2.97 s** (64 frames × 46.4 ms, 2 frames written per API call so 32 calls),
not an instantaneous RMS and not a smoothed one. Verified behaviour: it holds the peak
exactly flat after the note stops, then **drops to zero in a single step at call 32** — a hard
3-second peak-hold, no decay tail. Exactly proportional to input level: ratio
`MicRms / inputRMS = 0.239` constant across a 16× level sweep.

There is **no absolute level gate** — `CanHearANote` stayed true down to `MicRms = 0.0042`
(≈ −48 dBFS). Level is used only to normalise the salience, which is why the detector is
scale-invariant.

### 3.9 Reference pitch

Hard-coded **A4 = 440.000 Hz** (`MeasuredPitchMidi = round(12·log2(f/440) + 69)` clamped to
`[−48, 175]`; verified dead-on at 438/439/440/441/442 Hz). No user calibration hook.

---

## 4. Measured behaviour (the oracle)

I ran the real module under Node with a stub import table and drove it with synthetic and
semi-real signals. **Every number below is measured, not inferred.** Fresh module instance
per case, because the engine is a stateful singleton and leaks across cases.

### 4.1 Per-string accuracy, auto mode, 44.1 kHz, 7-harmonic tone, 80 frames

| String | Target | Reported Hz | Cents | `MeasuredPitchHz` error |
|---|---|---|---|---|
| E4 (idx 0) | 329.628 | 330 | +1 | +2.0 ¢ |
| B3 (idx 1) | 246.942 | 247 | 0 | +0.4 ¢ |
| G3 (idx 2) | 195.998 | 196 | +3 | +0.0 ¢ |
| D3 (idx 3) | 146.832 | 147 | +1 | +2.0 ¢ |
| A2 (idx 4) | 110.000 | 110 | +3 | +0.0 ¢ |
| E2 (idx 5) | 82.407 | 83 | +3 | +12.4 ¢ ← **entirely the `floor()` on Hz** |

**Accuracy: 0–3 cents on the cents channel across the whole guitar range.** This is
genuinely good — better than most chromatic tuners.

### 4.2 Latency

| Event | Frames (4096-sample calls) | Wall time @ 44.1 kHz |
|---|---|---|
| first `CanHearANote = true` | **3** | **279 ms** |
| `InTuneRatio > 0.9` (auto) | 14 | 1.30 s |
| `InTuneRatio > 0.9` (chromatic) | 15 | 1.39 s |

The first two calls always return `CanHearANote == false` regardless of input: the engine
needs three frames before it will name a note. That is a fixed ~186 ms of warm-up on top of
the 93 ms window.

The cents readout is live from frame 3 (≈ 279 ms), but the green "in tune" tick takes a
further 1.02 s. The +1 s JS hold on `CanHearANote == false` means a pluck decays gracefully
instead of flickering.

Note the mismatch that makes this feel sluggish: **2 FFT frames are computed per call but
only one vote is cast per call.** The 21.5 frames/s of analysis are being thrown away by the
confidence counter, which runs at 10.8 Hz. That is roughly 130 ms of avoidable latency on
the "in tune" verdict.

### 4.3 Robustness

| Test | Result |
|---|---|
| Harmonic content (sine / 2 / 3 / 7 / 8 / odd-only / square), auto mode | all detected, correct pitch |
| Noise, 20 dB SNR | detected, −8.6 ¢ |
| Noise, 3.5 dB SNR | detected, −8.6 ¢ |
| Noise, 0 dB SNR | detected, −8.6 ¢ |
| Noise, −4.4 dB SNR | detected, −8.6 ¢ |
| DC offset ±0.9 | +3 → +6 ¢ (leakage) |
| DC offset +2.0 | detected, +5 ¢ |
| DC offset +5.0 | **no note** (DC swamps the signal) |
| Level 0.02× … 6× (−34 dB … +15 dB) | detected at every level, identical cents |
| Sample rate 16 k / 22.05 k / 24 k / 48 k | detected, ≤ 12 ¢ |
| Sample rate 88.2 k | detected, 21 ¢ |
| Sample rate 96 k / 192 k | **wrong note / wrong octave** |
| Two strings at once (E2+E4, A2+A3, A2+E4) | locks the **lowest** one, correct |
| E2 + F#2 (a semitone apart) | **no note** |
| E2 + G3 (a fifth apart) | **no note** |

### 4.4 Chromatic mode is materially weaker than string mode

Detected in chromatic mode with 7 harmonics across MIDI 24…90, but with holes. Frequencies
that produce **no note at all**: 60, 61, 66–72, 79–83, 91–93, 102, 113, 135, 178, 350, 371,
490 Hz. Pure and 3-harmonic tones below ~130 Hz are never detected in chromatic mode. The
holes sit **between** filterbank band centres (65.0, 81.3, 98.4, 116.6, …), which is exactly
what a 91-cent grid with ±1-band triangular support predicts.

Because the web page only uses chromatic mode for the generic "Online tuner" and the
non-guitar instrument pages (bass, ukulele, violin, …) — and those pages *also* override the
cents and zero the ratio — the weak chromatic path is not on the guitar path.

**But it is on the bass path.** The filterbank's bottom edge is `T_lo[0] = 34.97 Hz`
(bin 7 = 37.68 Hz at 44.1 kHz, bin 6 = 35.16 Hz at 48 kHz) and that edge is *not* affected by
`setTuning` — the 56-band table is built from fixed constants. **A 5-string bass low B at
30.87 Hz is below it, and a 4-string bass low E at 41.20 Hz is only 1.2 bands up.** Worth
checking the live bass tuner before we assume that page is fine.

### 4.5 Sub-octave ceiling

Chromatic mode never reports above ~1320 Hz. A 1976 Hz tone reports 988 Hz, 2637 Hz reports
1318 Hz, 3951 Hz reports 1317 Hz. In string mode the search is clamped to the tuning, so a
6-string guitar is unaffected — but a **12-string high E (1976 Hz) or a 7-string B (2469 Hz)
would be out of range** unless `setTuning` widens the candidate grid.

### 4.6 Shutdown behaviour

After the note stops (silence input, same call cadence):

| calls after stop | `MicRms` | `CanHearANote` | `InTuneRatio` | `CurrentString` | `MeasuredPitchHz` |
|---|---|---|---|---|---|
| 0 – 12 | 0.20754 (held) | false | **1.00** | 5 | 83 (held) |
| 16 – 28 | 0.20754 (held) | false | 0.00 | −1 | 83 (held) |
| 32+ | **0.00000** | false | 0.00 | −1 | 83 (held) |

Two things worth copying: `CanHearANote` drops **immediately** on silence (no release
hysteresis in the engine — the 1 s hold is entirely the site's job), and `MicRms` is a hard
3-second peak-hold with a cliff, not a decay. `MeasuredPitchHz` is never cleared.

### 4.7 `PossibleWrongStringId`

When a specific string is selected but a different note is heard, the engine keeps
`CurrentString` on the selection (and reports the huge cents error) while adding a
suggestion:

| played | selected | `CurrentString` | `TuningErrorCents` | `PossibleWrongStringId` |
|---|---|---|---|---|
| E2 | B3 | 1 | −1897 | **5** (E2) |
| E2 | E4 | 0 | −2397 | **5** |
| E2 | E2 | 5 | +3 | −1 |
| A2 | D3 | 2 | −997 | **4** (A2) |
| C4 | E2 | 5 | +1999 | **1** (B3, nearest) |
| C4 | B3 | 1 | +99 | −1 (already nearest) |

This is a genuinely nice UX feature that is trivially cheap to reimplement.

---

## 5. Weaknesses worth naming

1. **`MeasuredPitchHz` and `TuningErrorCents` are `floor()`ed.** At E2 the Hz field has
   21 ¢ of quantisation. Any consumer that reads Hz gets a 20× worse answer than the
   engine actually has.
2. **Chromatic mode has structural detection holes** between filterbank band centres, and
   is unusable below ~130 Hz for anything thinner than 7 harmonics.
3. **The band grid is fixed at 91.4 cents with 2-band support.** Fine for a string tuner
   where you know the answer ±7 semitones; coarse for a general chromatic instrument.
4. **Semitone neighbours are rejected outright** (E2 + F#2 → nothing). Real guitars do not
   do this, but a capo or a slightly bent string can.
5. **Sub-octave ceiling ~1320 Hz** in the default configuration.
6. **1.30 s to "in tune"** because `InTuneRatio` is a 15-step counter that advances only once
   per API call, even though 2 FFT frames are computed per call. The cents readout is fast;
   the verdict is slow. There is ~130 ms of free latency being thrown away.
7. **`CanHearANote` has no release hysteresis at all** — it drops on the very next call after
   the signal stops. The 1 s hold is entirely the site's job, so the value is unsafe to
   consume on its own.
8. **No user A4 reference.** 440 is baked in.
9. **Anti-piracy domain check** — off `guitartuna.com`/`yousician`/`localhost` it returns a
   stub. Purely a commercial guard, and a reason the module is unpleasant to test against
   in CI without a `window.location` shim.
10. **Everything is a process-wide singleton** with no reset. There is no way to clear the
    smoothing state; a test harness has to instantiate a fresh module per case.

---

## 6. What is actually good about it

* **Cents accuracy: 0–3 ¢ across the guitar range**, sustained, at any input level from
  −34 dBFS to +15 dBFS, with no user calibration.
* **279 ms to a live cents reading**, then a further 1.02 s to the "in tune" verdict.
* **Scale invariance** comes free from salience normalisation — no AGC, no noise gate.
* **DC immunity** is a free consequence of discarding bins 0–6, not a bolted-on filter.
* **The string-prior design is the key idea.** Restricting the search to the instrument's
  own tuning turns a hard problem (chromatic polyphonic pitch) into an easy one (find the
  best of 6 hypotheses). That is why the guitar path is so much stronger than the
  chromatic path.
* **Harmonic-structure verification** on top of the salience peak is what kills
  single-spurious-bin locks.
* **Graceful decay** via a 1 s UI hold instead of a hard gate.
* **Free high-loudness handling** because the salience is normalised, not thresholded.

---

## 7. Reproducing this

The tooling lives in [`webtuna/`](webtuna/) — see its [`README.md`](webtuna/README.md).

| File | Purpose |
|---|---|
| `webtuna/harness.mjs` | instantiate the wasm with the real glue's import mapping; `analyse()` helper |
| `webtuna/iso.mjs` | fresh-instance-per-case factory (the engine is a stateful singleton) |
| `webtuna/rtti.py` | RTTI → vtable → class-map reconstruction |
| `webtuna/vmap.py`, `webtuna/fn.py` | extract functions from `WebTuna.dcmp` by name or index |
| `webtuna/state2.mjs` | live engine-state dump — this is where all the constants came from |
| `webtuna/window.mjs` | locate the `Ooura_FFT` object in the live heap; verify the window |
| `webtuna/cola.mjs` | verify window COLA and measure the `MicRms` release |
| `webtuna/tables3.mjs` | dump + verify the 56-band filterbank tables |
| `webtuna/frames.mjs` | prove frames-per-call and the `InTuneRatio` counter cadence |
| `webtuna/suite*.mjs` | the empirical characterisation in §4 |

Build steps:

```bash
brew install wabt
git clone --depth 1 --branch 1.0.41 https://github.com/WebAssembly/wabt
cmake -S wabt -B wabt/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF
ninja -C wabt/build wasm-decompile
./wabt/build/wasm-decompile WebTuna.wasm -o WebTuna.dcmp
node suite3.mjs
```

`WebTuna.wasm` is not committed (296 KB, and it is Yousician's IP) — fetch it from
`https://guitartuna.com/webtuna/WebTuna.wasm` and verify the SHA-256 in §0.

Caveat: `wasm-decompile` is absent from wabt ≥ 1.0.42 and from the Homebrew bottle. 1.0.41
is the last release that has it.

---

## Outcome: the Swift port was removed, this document was kept

The reference port (`StrumKit/Audio/WebTunaPitchDetector.swift`,
`docs/tuner-reliability/WEBTUNA_SWIFT.md`, and the settings-sheet A/B switch) has been
**removed from the app**. The production detector is the only detector.

This document and the `webtuna/` analysis tooling are kept deliberately: the
reverse-engineering is the evidence for the decision, and the decision is the reason this
project still has its own detector.

### What the comparison established

The A/B was run and it answered the question it was built to answer — **StrumKit's pipeline
is the better tuner.** Measured on the recorded quiet-pluck fixtures, the production path
holds a correct reading with 0 wrong notes and 0 string jumps, while the port reported a
note on only 11–26 of 104–160 frames (8–15% of the sound) despite estimating the correct
frequency whenever it did fire (439.2 / 262.3 / 328.9 / 391.6 Hz against true
440 / 261.63 / 329.63 / 392).

### Why it was removed rather than fixed

Three independent gates have to clear before the port names a note, and on real plucks
almost none of them do:

| fixture | as shipped | continuity off | harmonic-support off | both off |
|---|---|---|---|---|
| quiet_a | 16/104 | 24 | 11 | 43 |

Even fully unlocked it reaches only 43/104, because `pickPeak` declines to name a band at
all. On top of that the engine refuses to name anything for its first 5 hops (~107 ms at
the 48 kHz hop size), and its band table is built for a guitar's range while the fixtures
are ukulele.

The honest summary is that this is a *correct but strict* engine: every gate is a faithful
reading of the wasm, and each one was doing real work. The §3.6 harmonic-support gate in
particular is not a false-positive filter that can be loosened — turning it off collapses
quiet_c from 11 frames to 1 and quiet_g from 25 to 1. Fixing the port would have meant
re-tuning gates that were reverse-engineered correctly, at which point it stops being a
port of WebTuna and becomes a second, worse detector. The production algorithm was kept.

### Corrections to earlier claims in this document

Two claims made while porting were checked against measurement and are **wrong**:

- The port's `harmonicReference` was documented as defaulting to `.nextBand` while
  `.secondHarmonic` "handles a harmonically rich steady tone". Measured frames-with-note:
  `.nextBand` = 16/11/26/25, `.secondHarmonic` = 10/1/6/5. `.nextBand` is better on real
  plucks, and the steady-tone failure did not reproduce.
- "GuitarTuna's 0–3 cent accuracy" is largely its own quantisation, not precision.
  `MeasuredPitchHz` is `floor()`ed to whole Hz, which is ±21 cents at E2 (82.4 Hz), and
  `TuningErrorCents` is `(measuredMidi − stringMidi) × 100`, a distance in whole semitones
  rather than a detuning.

That last point is also the answer to "why does GuitarTuna *feel* smoother than ours when
its algorithm is no better": its detector output is quantised to ~21-cent steps at E2, and
the calm comes entirely from animating the presentation. Our own detector produces
continuous cents, and the gauge now eases between readings
(`HardwareGaugeView`), which is the same trick applied to better data.

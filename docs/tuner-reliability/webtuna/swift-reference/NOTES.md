# NOTES — the three places `WEBTUNA.md` surprised me

These are the places where I stopped and re-derived something from the running
module, because the report and the binary disagreed. They are where our
understanding is most likely to be wrong in general, not just in this port.

---

## 1. The filterbank's own constants do not reproduce the filterbank

`WEBTUNA.md` §3.3 gives the formula

    T(off)[k] = (10^(0.046804 · max(0, 2.318973 + 0.5k + off)) − 1) · 228.937714

and `docs/tuner-reliability/webtuna/tables3.mjs` verifies it that way, reporting
a max absolute error of ~0.15 Hz. I initially read that as float32 noise. It is
not: evaluating the formula in double precision and comparing against the live
float32 tables gives a **relative** error of 8.0e-5 at band 0, rising to
2.5e-5 × the frequency at band 55 — i.e. **0.15 Hz out of 5464 Hz at the top,
which is a tenth of an FFT bin**.

Fitting the two constants to the five live values I could read
(`T_ctr[0]`, `T_lo[0]`, `T_hi[0]`, `T_ctr[55]`, `T_hi[55]`) — golden-section on
the exponent, scale solved from `T_ctr[0]` — gives

    exponent = 0.04680435    scale = 228.93762

which reproduces **all five to 7.4e-8**, i.e. to float32 epsilon, with two free
parameters and five observations. That is not a coincidence and not an
overfit: the exponent `0.046804` is a six-significant-digit rendering of
`0.04680435`, and the ~7.5e-6 relative error in it is most of what the reported
`228.937714` is compensating for.

The port uses the fitted pair and asserts on the live values.

**What this suggests about the rest of the report.** Any constant in
`WEBTUNA.md` that was read out of the decompile rather than out of the live heap
should be treated as six-significant-digit-accurate at best. There are at least
three such constants that matter (this one, the semitone, the cube-root
exponent) and I found them by accident rather than by looking. The report's
*derived* claims — the COLA measurement, the DC-immunity result, the per-string
accuracy table — were measured against the live module and I have no reason to
distrust them.

---

## 2. The 675-entry grid is the guitar's grid, not the engine's ceiling

§3.5 presents the candidate grid as `MIDI 26 + k/15`, 675 entries spanning
MIDI 26–70.93, and then hedges — correctly, as it turns out, but for the wrong
reason — that "the 675-entry grid is clearly a *coarse* search that is then
refined, not the final resolution".

It is not coarse-and-refined. It is exactly the guitar's own tuning span, and
**chromatic mode builds a different, much larger grid**: base MIDI 15, 75
semitones, 1125 entries, up to MIDI 89.93. The grid is the search bound, and the
bound is the tuning. That is §6's "the string-prior design is the key idea"
showing up as a literal data structure rather than as an emergent property.

Which also retires §4.5's "sub-octave ceiling": 1320 Hz is where the *detector*
stops, not where the grid stops, and the grid has headroom to MIDI 90.

I would not have found this from the report. It came from noticing that the live
`grid[0]` for `stringIdx = -2` is 19.445 Hz, not 36.708 Hz.

---

## 3. `MeasuredPitchHz` is `rint`, which halves a documented weakness

§1.4 and §5.1 both say the two numeric outputs are `floor()`ed, and §5.1 leans on
it: "at E2 one Hz is 21 cents, so the reported Hz has ±21 ¢ of quantisation", and
a table entry that attributes E2's entire 12.4 ¢ error to "the `floor()` on Hz".

The decompile says `f_hc(g[34])`, and `f_hc` is `roundeven` — it computes
`(a + 2^23) − 2^23 − a` and branches on ±0.5, which is the round-half-to-even
construction, not truncation.

The measurement settles it. A 7-harmonic E2 tone gives the engine
`MeasuredPitchHz = 83` and `TuningErrorCents = 3`. Three cents above E2 puts the
internal frequency at 82.565 Hz. `floor(82.565) = 82`; `rint(82.565) = 83`. So it
is `rint`, and the quantisation is **±10.5 ¢ at E2**, half what §5.1 claims.

**Why this is worth more than a rounding mode.** §5.1 is the list of weaknesses,
and it is the section a reader would quote. It currently says the Hz channel is
20× worse than the cents channel. It is 10× worse. A weakness list that
overstates a weakness by 2× is a weakness list that has been reasoned about
rather than measured, and the rest of §5 deserves the same suspicion — which is
the real reason I re-derived the filterbank constants by hand instead of trusting
`tables3.mjs`'s "verified" claim.

---

## Also worth knowing, not in the report

* **The decompiler's field indices do not survive into the real struct layout.**
  This cost me most of the time on this port and it is the single biggest
  obstacle to finishing D6. Concretely: the code reads `m[5]` where the
  arithmetic needs the sample rate, and `m[5]` is 8192; `j[0]` holds 52.0, a
  millisecond threshold §3.1 never mentions. Every `k[n]` / `m[n]` / `j[n]` index
  in `func708` should be treated as a *hint*.
* **`wasm-decompile` truncates float literals to six significant digits**, which
  silently breaks `0.083333f` (really 1/12) and `0.333333f` (really 1/3). Both
  matter: the first is 3.7 cents of pitch error on the first grid entry, the
  second is 19 % on the salience.
* **The FFT is a complex 8192-point transform, not a 4096-point real one.**
  `vDSP_fft_zrip` is the obvious choice and it is wrong: it halves every bin
  number, so a tone on bin 15 lands on bin 7. The engine zero-pads and takes a
  full complex transform. The live spectrum settles it — 80.75 Hz peaks at bin 15
  (8192-point) and would peak at 7.5 (4096-point real).

# Divergences

Every place this port does **not** match `WebTuna.wasm`, and what I believe the
real code does. Ordered by how much they matter.

The point of listing these is that a documented divergence is a finding, and a
silently-fudged one would destroy the port's purpose. Nothing here is a
tolerance loosened to make a test pass.

---

## D6 — Stages 4 and 6 could not be verified, and the port does not match them

**Severity: the main open problem.** This is the one that matters.

### What was attempted

`tools/probe-intermediates.mjs` finds, in the engine's `Ooura_FFT` object, a
56-float array `A` and a second 56-float array `B` such that

    B[k] = (sqrt(A[k]/4095) * 1.414214)^(1/3)      to 1.3e-7 relative

which is float32 round-off. So the *pair* is real and is the §3.4 salience
transform, with `A` the input.

### Why `A` is not the filterbank output

For a 7-harmonic E2 tone, `A` decays smoothly from 9.5e-4 at band 0 to 2.2e-10
at band 55, and for bands 21…55 it decays at a *fixed* 0.87 per band. Over the
same band range the engine's own spectrum is a flat ~1.2e-6 per bin. A positive
weighted sum over fifty bins of a 1.2e-6 floor cannot be 2.5e-8 — the two differ
by four orders of magnitude. Quantitatively, a weighted sum computed from the
decompile's triangle is **51×** larger than `A[0]`, **431×** larger than `A[20]`,
and **6.0e5×** larger than `A[52]`.

The discrepancy also grows monotonically with band index, which rules out a
simple missing scale factor.

### What I believe the real code does

Two candidates, not distinguishable with the evidence I have:

1. **`A` is not the filterbank output at all.** It satisfies the §3.4 relation
   against `B`, but the §3.4 relation is invertible — *any* 56-float array
   produces a matching `B`. So the pair being real says nothing about `A` being
   the band values. It is more likely the *resampled* or *harmonic-summed* array
   from §3.5–3.6, which is also 56 long. The genuine filterbank output was not
   located, so stages 4 and 5 could not be checked value-by-value at all.
2. **The filterbank is not a weighted sum.** Something that makes the high bands
   fall to 1e-10 while the spectrum is flat at 1e-6 would have to be a
   cancellation or a much narrower support. Possible, but I found no mechanism.

### Consequence for the port

`Filterbank.bands` follows the decompile (a per-bin triangular weighted sum) and
`WEBTUNA.md` §3.3. It is **unverified**. So is the resample onto the candidate
grid and the harmonic-support index mapping, which sit directly downstream.

### What would settle it

A scan of the whole heap for 56-float arrays whose band 0 is within a small
factor of the weighted sum, rather than the six candidates `probe-intermediates`
looks at inside the `Ooura_FFT` object. The band loop writes to `m[18]`
according to the decompile, and the decompile's *field indices demonstrably do
not survive into the real struct layout* (I hit this repeatedly: `m[5]` is 8192
where the decompile's arithmetic needs the sample rate, `j[0]` is 52.0 where
§3.1 never mentions it). The field-index mapping is the actual blocker, and
fixing it is the highest-value next step.

---

## D7 — Stage 7: the harmonic-support tests gate a *search*, not a rejection

**Severity: the largest single cause of the `CurrentString` and `InTuneRatio`
mismatch.**

`func708` lines 887–894:

```
if (eqz( (ca / nextHigherHarmonic) > 2.0 ) | eqz( (ca / previous) > 0.4 )) goto B_qd;
if (eqz( ca > k[20] + previous )) goto B_qd;
    ... the "new detection" path, which sets k[22]=0, k[76]=1, k[18]=a ...
label B_qd:
    ... a 50-line continuity search over the candidate array ...
```

So the three tests are the **entry condition for the new-detection path**, and
failing them routes the candidate into a continuity search that in most cases
re-accepts it. The port treats failure as rejection.

`WEBTUNA.md` §3.6 describes them the way the port implements them ("must all
hold, else the candidate is rejected"). **The prose is a reasonable reading of an
ambiguous branch and it is wrong about the consequence.** The port follows the
prose, and records the disagreement here rather than silently picking the
decompile's reading, because the decompile's field mapping around that search is
also unreliable (see D6) and the port could not implement the search faithfully
in the time available.

Measured effect: with the gate as a rejection, `CanHearANote` agrees on 85.5 % of
calls and `CurrentString` on 3.3 %. The engine's `CurrentString` behaviour that
the port does not reproduce is mostly this search.

Also unresolved in stage 7: the exact cadence of `g[28]` (the stability counter).
The live engine reaches 6 after two calls, i.e. +3 per call, which is not the
plain "+1 per call" §3.6 implies; the decompile's increment expression at line
1207 involves a `select_if` whose operands I could not resolve against the live
values. The port uses +1 per call.

---

## D1 — `MeasuredPitchHz` is `rint`, not `floor`

**Severity: small, but it changes a documented weakness.**

`WEBTUNA.md` §1.4 and §5.1 both say `MeasuredPitchHz` and `TuningErrorCents` are
`floor()`ed, and §5.1 builds an argument on it: at E2, "±21 ¢ of quantisation",
and a table entry attributing E2's 12.4 ¢ error to "entirely the `floor()` on Hz".

The decompile is `f_hc(g[34])` where `f_hc` is `roundeven`
(`roundeven` / round-half-to-even — the code computes `(a + 2^23) − 2^23 − a` and
branches on ±0.5, which is exactly the round-half-to-even trick).

Measured: for a 7-harmonic E2 tone the engine reports `MeasuredPitchHz = 83` and
`TuningErrorCents = 3`. Cents 3 from E2 puts the internal frequency at
82.4069 · 2^(3/1200) = **82.565 Hz**, and `floor(82.565) = 82`, not 83.
`rint(82.565) = 83` ✓.

So `MeasuredPitchHz` is `rint` and the quantisation is **±10.5 ¢ at E2, not
±21 ¢** — a real, if unglamorous, correction to the weakness list.
`TuningErrorCents` *is* `floor`, of the cents error.

---

## D2 — The salience divisor is `4095`, not the analysed bin count

`WEBTUNA.md` §3.4 writes `a[k] = (sqrt(2·max(mag,floor)/nBins))^(1/3)` without
saying what `nBins` is. It is the **real** FFT size minus one, `1/4095`, not
`2/1130`. A factor of 3.6. It is scale-invariant for the peak picking, so it does
not change the detector's behaviour, but it does change the arrays.

The `1.414214` also multiplies the **square root**, it is not inside it:
`a[k] = (sqrt(m/4095) · 1.414214)^(1/3)`, i.e. `x^(1/6)` as §3.4 says.
`wasm-decompile` renders it inside the argument list, which would give
`sqrt(1.414214 · m/4095)` — wrong by 19 %.

---

## D3 — The filterbank support is ±2 bands, not ±1

`WEBTUNA.md` §3.3 says "`T_lo[k] = T_ctr[k−1]`, `T_hi[k] = T_ctr[k+1]`, … ±1-band
triangular support". Its own formula contradicts it: the exponent argument is
`2.318973 + 0.5k + off`, so `off = ±1` moves it by a full 1.0, which is **two**
band steps of 0.5.

Confirmed against the live tables: `T_lo[0] = 34.9693` is `T_ctr[−2]`, and
`T_lo[2] == T_ctr[0] == 65.0000` exactly. The nominal half-width is
`10^0.04680435` = 1.1138 = **182.8 cents**, which is the "≈183 cents effective
resolution" §3.3 quotes — so §3.3 is internally inconsistent and the 183 cents is
the correct figure.

A second consequence: the `(10^x − 1)` term makes the table **non-geometric at the
bottom**. `T_lo[0]/T_ctr[0] = 0.538`, not `1/1.1138 = 0.898`, so band 0 is a
very wide triangle in cents terms. That is the mechanism behind §4.4's "a 4-string
bass low E at 41.20 Hz is only 1.2 bands up".

---

## D4 — Two float literals in the decompile are six-significant-digit truncations

`wasm-decompile` renders float literals to six significant digits, and two of the
constants in the hot path are wrong at that precision:

| Rendered | Actual | Evidence |
|---|---|---|
| `0.083333f` (semitone) | **1/12** | `f32(1/12)` reproduces the live `grid[0] = 36.7080917` to 1e-9; `0.083333` gives 36.7084618, a 1.0e-5 relative error = 3.7 cents on the very first grid entry |
| `0.333333f` (cube-root exponent) | **1/3** | the engine's own `a[]` matches `(x)^(1/3)` to 1.3e-7 |
| `0.046804` (filterbank exponent) | **0.04680435** | see below |

Any other `0.083333f`-shaped constant in a decompile should be treated as
suspect.

---

## D5 — `MicRms`: two details §3.8 does not give, both load bearing

* The divisor is the **top bin index**, 1136 at 44.1 kHz — not the count of bins
  read (1129) and not the frame size. Verified: the engine's own `spectrumRMS`
  equals `sqrt(Σ/1136)` to the last float32 digit; `sqrt(Σ/1129)` differs by
  0.3 %.
* The engine's spectrum holds bins **0…5 as exact zeros and bin 6 non-zero**
  (measured: 3.345e-4 for a 7-harmonic E2 tone). This is a separate constant from
  the filterbank's `lowestBin = 7`. Zeroing one bin too many costs 1.8e-5 of the
  RMS, which is the entire residual error in `MicRms` if you get it wrong.

With both right, `MicRms` matches on 1280/1280 calls.

---

## D8 — The candidate grid is bounded by the tuning, and chromatic widens it

`WEBTUNA.md` §3.5 records the 675-entry grid (MIDI 26 → 70.93) and then hedges
that "the 675-entry grid is clearly a *coarse* search that is then refined".

It is not a coarse search that gets refined — it is **the guitar's own grid**,
and chromatic mode builds a different one. `f_sk` is called with (35, 64) in
string/auto mode and with (21, 83) in chromatic mode; after `f_sk`'s base-MIDI
transform (`b > 40 ? b−14 : min(b,32)−6`) that gives base MIDI **15** and a
75-semitone span, i.e. **1125 entries up to MIDI 89.93**. Read out of the live
object: `grid[0] = 19.4454365 Hz = MIDI 15.000`, 1125 entries.

So §4.5's "chromatic mode never reports above ~1320 Hz" is a property of the
detector, not of the grid, and §3.5's caveat can be retired.

---

## D9 — The `InTuneRatio` counter's first step is +3, not +1

`WEBTUNA.md` §3.7 tabulates `g[48]` as `0, 3, 4, 5, …` and calls it "+1 per
call", which does not describe its own first row. The decompile shows why: the
increment is 1 normally, but on the frame that first flags the note it is
`g[14] + 1`, where `g[14]` is the count of consecutive agreeing frames — which is
2 after two frames, hence +3.

This matters because it is the whole of the "3 calls to first note, 12 more to
in tune" arithmetic in §3.7–§4.2: without the bonus it would be 15 calls at +1
anyway, but the *shape* of the ramp is different, and anything that keys off
"ratio increased by exactly 1/15" will be wrong on one call out of fifteen.

The port does not implement the bonus.

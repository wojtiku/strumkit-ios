# StrumKit

An iOS tuner for fretted string instruments. It listens to a microphone, decides what
pitch is sounding, and tells the player how far it is from the note they are aiming at.

## Language

### The instrument

**String**:
One of the instrument's tuned pitches, identified by position — the low E on a guitar is a
string, not a note.
_Avoid_: Note, fret

**Tuning**:
The set of pitches an instrument's strings are currently set to.
_Avoid_: Preset, Scale

**Preset**:
A named, shipped **Tuning** the player can select (Standard, Drop D, Baritone).
_Avoid_: Tuning, Default

**Custom tuning**:
A **Tuning** the player defines by hand, one **String** at a time.
_Avoid_: Preset, Manual tuning

**Calibration**:
The reference frequency assigned to A4. Decides what every other frequency means.
_Avoid_: A4, Reference pitch, Tuner reference

**Instrument**:
A family of **String** counts and **Tuning** **Preset**s the tuner can offer — guitar,
ukulele.
_Avoid_: Category, Type

### What is heard

**Note**:
A named pitch, independent of any string — E2, A4, F♯3.
_Avoid_: String, Target

**Reading**:
One observation of what is sounding: the **Note** heard, how far it is from where it should
be, and the grade of **Evidence** behind it.
_Avoid_: Detection, Result, Frame, Pitch result

**Level**:
How loud the input is, and how loud what was heard within it. Determines whether a
**Reading** is possible at all.
_Avoid_: Volume, Amplitude, Signal strength, Gain

**In tune**:
A **Reading** is in tune when it is confirmed by 400 ms of continuous measured evidence
within tolerance of its **Target**. Visual proximity (within ±5 cents) provides needle feedback,
but completion and the in-tune verdict require sustained measured confirmation over this 400 ms
window, preventing spurious transitions from brief frequency crossings or noise.
_Avoid_: Accurate, Correct, Tuned

### What the player is aiming at

**Target**:
The **String** a **Reading** is being measured against — a thing the player is *trying* to
reach, which exists whether or not anything is currently sounding.
_Avoid_: Note, Expected note, Reference

This is the distinction that separates the tuner's two modes:

- In **String** modes the player aims at a **String**, and deviation from it is advice:
  "turn the peg."
- In **Chromatic** mode nothing is being aimed at. The tuner names the **Note** it hears and
  reports its distance from equal temperament, which is not advice about any **String**.

A **Reading** in Chromatic mode therefore has a **Note** and no **Target**, and is never
"in tune" in the sense above.
_Avoid_: (for the Chromatic-mode case) Target, Detected target

### How much a Reading can be trusted

**Evidence**:
Where a **Reading** came from, graded in two levels. **Measured** evidence includes
current-window audio observations accepted by the detector — whether established by periodicity
autocorrelation or supported spectral energy in the current window. **Sustained** evidence extends
a **Note** already being tracked across missing, quiet, or held frames when fresh detection has gone
quiet but the note has not. Only **Measured** evidence may declare a **String** in tune or complete
a **Tuning** sequence; **Sustained** evidence may show a reading and nothing more.
A **Reading** always states its grade and there is no default one, so a path that produces a
**Reading** has to choose a level rather than inherit whichever the last path happened to use.
_Avoid_: Confidence, Score, Trust, Certainty, Quality

Only **Measured** evidence completes a **Tuning** sequence, and only **Measured** evidence is
presented without de-emphasis.

A third grade — **Acquired**, naming a **Note** nothing else has confirmed — was defined here
and then withdrawn. The path that produced it was measured and found blocked: its gate
rejected exactly the weak fundamentals it existed to rescue, and no discriminator separating a
real quiet **Note** from broadband noise was found. The finding is kept in
`docs/tuner-reliability/RESULTS.md` §13. It is named here because the concept is the obvious
next one to reach for, and reaching for it without that finding is how it gets rebuilt wrong.
Its failure mode is worth keeping: **Acquired** would be the one grade that can name a **Note**
that is not sounding at all, which is worse than naming the cents of a **Note** that is.
_Avoid_ (as a grade): Recovered, Salient

### Over time

**Fresh reading**:
A **Reading** backed by **Measured** evidence from audio observed in the current window.
Fully authoritative.
_Avoid_: Current, Live, New

**Held reading**:
The last **Fresh reading**, retained on screen for up to 1000 ms after audio detection ceases,
deliberately de-emphasised with **Sustained** evidence. It preserves the last observed values
and its original `lastFreshAt` timestamp without re-aging as fresh, serving as a memory of what
was heard rather than a claim about what is being heard now.
_Avoid_: Stale, Cached, Last seen

**Sustain**:
A **Note** still ringing after the pluck, too quiet for fresh detection but still
identifiable because it is the same **Note** as before.
_Avoid_: Decay, Ring, Tail, Continuity prior, Prior

## Deliberately not domain terms

These words describe how the app is built, not what a tuner knows. They belong in
architecture documents, not here.

Reading/Frame, Generation, Snapshot, Generation counter, Mailbox, Seam, Module, Interface,
Depth, Adapter, Pipeline, Worker, Snapshot, Target *string* (as in a literal `String`).

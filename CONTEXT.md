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
be, and how much the tuner trusts it.
_Avoid_: Detection, Result, Frame, Pitch result

**Level**:
How loud the input is, and how loud what was heard within it. Determines whether a
**Reading** is possible at all.
_Avoid_: Volume, Amplitude, Signal strength, Gain

**In tune**:
A **Reading** is in tune when it falls inside a tolerance of its **Target**. The tolerance
is wider to leave than to stay in, so a **Reading** hovering at the edge does not flicker.
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
Where a **Reading** came from, graded in three levels. **Measured** evidence is periodicity
found in the audio itself. **Sustained** evidence extends a **Note** already being tracked,
when fresh detection has gone quiet but the **Note** has not. **Acquired** evidence names a
**Note** nothing else has confirmed. Only **Measured** evidence may declare a **String** in
tune; **Sustained** and **Acquired** may show a reading and nothing more.
_Avoid_: Confidence, Score, Trust, Certainty, Quality

Only **Measured** evidence completes a **Tuning** sequence, and only **Measured** evidence is
presented without de-emphasis.

**Sustained** and **Acquired** evidence are treated alike today. That is a decision to wait
on measurement, not a claim that they are equivalent: their failures differ in kind
(**Sustained** gets the cents wrong on a **Note** that is genuinely sounding; **Acquired**
names a **Note** that is not there at all), and whether the second warrants a weaker rule
than the first is open. See
`docs/superpowers/plans/2026-09-25-detection-layer-phases-0-3.md`, which is measuring it.

### Over time

**Fresh reading**:
A **Reading** backed by evidence from audio heard just now. Fully authoritative.
_Avoid_: Current, Live, New

**Held reading**:
The last **Fresh reading**, still on screen after the sound stopped, deliberately
de-emphasised. It is a memory of what was heard, not a claim about what is being heard now.
_Avoid_: Stale, Cached, Last seen

**Sustain**:
A **Note** still ringing after the pluck, too quiet for fresh detection but still
identifiable because it is the same **Note** as before.
_Avoid_: Decay, Ring, Tail

## Deliberately not domain terms

These words describe how the app is built, not what a tuner knows. They belong in
architecture documents, not here.

Reading/Frame, Generation, Snapshot, Generation counter, Mailbox, Seam, Module, Interface,
Depth, Adapter, Pipeline, Worker, Snapshot, Target *string* (as in a literal `String`).

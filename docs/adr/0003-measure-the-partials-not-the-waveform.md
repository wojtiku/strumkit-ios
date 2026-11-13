# 0003 — The detector names the note; the partials measure it

## Status

Accepted.

## Context

The app ran a bit-exact port of the web tuner: a waveform period detector feeding a tracker
with a median, an exponential smoother and a set of special cases for steps, decays and
re-plucks. Parity with the reference was proven frame by frame.

Parity was with the wrong thing. Measured on the recorded fixtures:

- On a quiet C4 the string's fundamental stays within one cent for three seconds. The
  detector's frequency over the same audio jitters by ten cents hop to hop and drifts to
  +16 as the note fades. The period that best explains the whole waveform is pulled around
  by partials that are not exact multiples of each other, decay at different rates, and
  sink into the noise at different times.
- The tracker hid that with time constants of up to a second, which made the needle slow
  without making it right.
- The web page draws ±200 cents across its meter; the app draws ±20 across its gauge. The
  same wander is ten times larger on screen, which is why the port looked worse than its
  original.

## Decision

The engine has two paths, chosen at construction.

`.precise` is what the app runs. The detector is kept for what it is good at — deciding
which note is sounding, and its octave. `PartialLock` then measures the first four partials
individually, each in a narrow band over a 170 ms window, and combines them weighted by how
steady each has been and how far it stands above its local noise; the reading is referred
to the lowest partial present. `ReadingTracker` follows that with a three-hop median and a
low-pass whose cutoff rises with the speed of the pitch, and confirms in tune after 400 ms.
The display is told about every hop and the needle is a spring.

`.reference` is the port, untouched, and is what the parity suite drives.

## Consequences

- The parity suite proves the port, not the product. `PrecisePipelineTests` holds the
  product to what it is for: a band of a few cents on a string that is not moving, and a
  cent of accuracy through noise and stretched partials.
- A note is shown for slightly less of its tail. The lock stops when no partial stands
  20 dB above its surroundings, where the old path carried on with readings that were not
  measurements. The one-second hold covers the difference.
- The reading follows a moving pitch about a tenth of a second behind.
- Chromatic mode is chromatic: it names any note in range, where before it could only name
  one within 250 cents of a string of the selected tuning, and it is smoothed like every
  other mode.

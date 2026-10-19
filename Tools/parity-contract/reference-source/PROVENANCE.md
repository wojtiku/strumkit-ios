# Reference Source Provenance & Licensing

## Authority
- **Repository**: `test-tuner` (`https://github.com/wojtiku/test-tuner` / local `/Users/wojtiku/src/test-tuner`)
- **Authority Commit**: `6a5a4f30304f392ff9dec9997633f83c295e1e1b`
- **Author**: Wojciech Urbański <wojtiku@gmail.com>
- **Native Starting Point**: StrumKit `b5075fd94bcb7d9df8161c98536fe08d09bcdd27`

## Permitted Own-Source Licensing
All source files under `reference-source/` are the original own-source work of Wojciech Urbański.
They are imported into `strumkit-ios` specifically for the purpose of a 1:1 faithful Swift port and parity verification.
No external third-party WASM, WebTuna, or closed-source oracle code is included or depended upon.

## Pinned Source Files & SHA-256 Hashes
| File | SHA-256 |
| --- | --- |
| `pitch.ts` | `009c7b4c357fe729012da21394c69e433264a525b6c0e38216e3fb7bd7ca4fe1` |
| `spectrum.ts` | `90c67aec8cf7769380da5dfb93d95a1b61725feb9fcfc814b0a7b022e57b1b81` |
| `tuning.ts` | `a744f4cc7033e885b2d48608b1e9327e4fb22606a781be1de2870f3de9aa83ff` |
| `presentation.ts` | `f16d7bc502a6350e6a4db29b542621174acd652ad7db75fe0eca6767ba0bcc0f` |
| `feedback.ts` | `5b90171a9e113c12cdcbaa0243dd4a5260036e52c550476d6ae28c714cab5ab1` |
| `audio-worklet.ts` | `99e5390bee0d655ee2a30c02b9dbf0594bb1202843e7573421f7e04a6a340f9c` |
| `main.ts` | `dd31f09b268ac673abef9cba337a032caaec0799975c4fa3fe372f307ec322b7` |

## Authoritative Construction Paths and Parameter Defaults
The authoritative product algorithm consists of:
1. **Framing** (`audio-worklet.ts`):
   - Window size: 4096 samples at capture rate.
   - Hop size: 1024 samples (75% overlap).
   - Reblocks arbitrary callback buffer sizes (e.g. 128-sample render quantums).
   - Analysis begins only after a full 4096-sample window is filled.
   - Parity audio clock timestamp is the start of the final 128-sample quantum: `(start + 4096 - 128) / sampleRate * 1000` ms. Offline batch reports use window end: `(start + 4096) / sampleRate * 1000` ms.
2. **Detector** (`pitch.ts`):
   - `createPitchDetector()`
   - Defaults: `ranking = 'prominence'`, `repairFallback = true`, `repairWaveform = true`, `refineWeak = true`, `recoverNull = true`, `repairSpectralOctave = true`, `refineForeground = true`.
   - Frequency range: 110 Hz to 1100 Hz.
   - Biquads reset to 0 at every frame (not a continuous streaming state).
   - FFT: radix-2 Double, Hann window denominator N-1, zero-padded to 8192 for 4096 input.
3. **Tracker** (`tuning.ts`):
   - `new TunerTracker()`
   - Defaults: `maxSlewCentsPerMs = 0.75`, `greenPolicy = 'raw'`, `motionTrial = 'fast-persistence64-away-rearm-bootstrap'`, `bootstrapConfidence = 0.98`, `bootstrapSeed = 'mean'`, `decayDamping = true`.
   - Target acquisition: nearest standard target with 25-cent hysteresis, 250-cent maximum rejection.
   - Target notes (standard): G4 (391.995 Hz), C4 (261.626 Hz), E4 (329.628 Hz), A4 (440.000 Hz).
   - Smoothing: 5-frame median, adaptive time constant (50 ms responsive / 220 ms steady / 500 ms decay / 1000 ms damped decay), 0.75 cents/ms max slew.
   - In-tune confirmation: settled within ±5 cents for >= 400 ms.
4. **Presentation** (`presentation.ts`):
   - `new TunerPresentation()`
   - Display throttling: 12 Hz (`1000 / 12` ms minimum spacing).
   - Hold duration: 1000 ms before resetting to null (empty).
5. **Feedback** (`feedback.ts`):
   - `new TuningFeedback()`
   - Proximity: within ±5 cents of selected target.
   - Confirmation: earned 400 ms `inTune` status triggers a one-shot string completion event.

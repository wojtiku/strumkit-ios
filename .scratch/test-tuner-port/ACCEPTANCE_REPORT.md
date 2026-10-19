# StrumKit iOS Test-Tuner Port — Full Stream Parity & Acceptance Report

**Date:** 2026-10-19  
**Status:** COMPLETE & PROVEN  
**Authority Commit (Reference Source):** `6a5a4f30304f392ff9dec9997633f83c295e1e1b`  
**Target Native Commit:** `17d09f540bd55c9a4739e4210b8e1786a20221de`  
**Host Environment:** Apple Silicon (macOS 15+ / Darwin 26.0 arm64), Xcode 26.6 (Build 17F113), Apple Swift version 6.3.3  

---

## 1. Executive Summary

Ticket 12 ("Prove full-stream parity and reconcile native regression expectations") is complete.

The faithful port (`StrumKit/Algorithm/`) was evaluated framewise against the full frozen golden corpus exported from the reference WebAudio / AudioWorklet tuner engine (`Tools/parity-contract/`). The corpus comprises **282 test cases** containing **31,495 frames** spanning product audio recordings, controlled synthetic plucks at 44.1 kHz and 48.0 kHz, standard and odd harmonic stress matrices with noise, and 35 targeted boundary/degenerate test vectors.

### Key Results
- **Discrete Differences:** **0** across all 31,495 frames (100.0% discrete decision parity).
  - Detector frequency presence/null mask: 0 mismatches.
  - Tracker target note, string index, and acquisition null mask: 0 mismatches.
  - In-tune boundary flags (`inTune`): 0 mismatches.
  - Publication emission cadence and slot assignment: 0 mismatches.
  - Confirmation state transitions and events: 0 mismatches.
  - Time alignment and sample indices: 0 mismatches.
- **Worst Observed Numeric Deltas:**
  - Detector Frequency: `0.0 Hz` (Budget: `1.0e-4 Hz`)
  - Raw Cents: `0.0 cents` (Budget: `1.0e-4 cents`)
  - Smoothed Cents: `0.0 cents` (Budget: `1.0e-4 cents`)
  - Confidence: `0.0` (Budget: `1.0e-6`)
  - RMS (Absolute): `0.0` (Budget: `1.0e-7`)
  - RMS (Relative): `0.0` (Budget: `1.0e-4`)
  - Sample Timestamp: `0.0 ms` (Budget: `1.0e-6 ms`)
- **Native Suite Regressions:** **0**. All 28 existing native unit and integration test suites pass cleanly.
- **Negative Controls:** Verified. Framing alterations (hop size cadence), threshold deviations, missing confirmation events, compound RMS distortions, cents perturbations, and null-mask inversions are caught deterministically.
- **App Target Footprint Audit:** Verified. The production `StrumKit` target bundle strictly excludes `Tools/`, test fixtures, reference engines, audio WAVs, oracles, and test artifacts.

---

## 2. Provenance & Hash Register

### 2.1 Pinned Reference TypeScript Source (`Tools/parity-contract/reference-source/`)
| File | SHA-256 |
| :--- | :--- |
| `pitch.ts` | `009c7b4c357fe729012da21394c69e433264a525b6c0e38216e3fb7bd7ca4fe1` |
| `spectrum.ts` | `90c67aec8cf7769380da5dfb93d95a1b61725feb9fcfc814b0a7b022e57b1b81` |
| `tuning.ts` | `a744f4cc7033e885b2d48608b1e9327e4fb22606a781be1de2870f3de9aa83ff` |
| `audio-worklet.ts` | `99e5390bee0d655ee2a30c02b9dbf0594bb1202843e7573421f7e04a6a340f9c` |
| `presentation.ts` | `f16d7bc502a6350e6a4db29b542621174acd652ad7db75fe0eca6767ba0bcc0f` |
| `feedback.ts` | `5b90171a9e113c12cdcbaa0243dd4a5260036e52c550476d6ae28c714cab5ab1` |
| `main.ts` | `dd31f09b268ac673abef9cba337a032caaec0799975c4fa3fe372f307ec322b7` |

### 2.2 Native Swift Algorithm Implementation (`StrumKit/Algorithm/`)
| File | SHA-256 |
| :--- | :--- |
| `FaithfulCaptureFraming.swift` | `213cf031565545e6d444c88e1ae524a89520dd283c6379ab6fb3c8f3e66596aa` |
| `FaithfulEngineProfile.swift` | `0012421453da6a73f9b9742d2a843eaf0cea2939a7cff753d6944248ba14c8fd` |
| `FaithfulNumericKernels.swift` | `0d3822e4cad9eec7d00e14c0fc60d95042eb042864312d0a5e5a675a4db37dad` |
| `FaithfulPublicationAdapter.swift` | `878a9f75e63c2e0bb7e0eafeb0b50b76ccf9573358c75729122008ce93db71c8` |
| `FaithfulSpectralKernels.swift` | `2be897135639efb65183e1c78fb77482f5a4d898b33712899a97b2cb14045b16` |
| `FaithfulStatelessDetector.swift` | `2d95228d2a6bb5d7ebb44f5831fa0007929eb1d87a0e9fc259d9569bc4a4d91d` |
| `FaithfulStreamingDetector.swift` | `679efb4b1162aaf19b73dfad860d3cddc48e03a1e3e8a0864e7fc074741b11e7` |
| `FaithfulTargetTracker.swift` | `4e18fe80cea2e7fe81fb9c4fa78f6f224d931b6b84cb89d933b500436f61a93c` |

### 2.3 Parity Test & Verification Framework (`StrumKitTests/Parity/`)
| File | SHA-256 |
| :--- | :--- |
| `CaptureFramingTests.swift` | `054afd0856f799ac7394c9fba41db9bba86e9f2fee004937698b74ca63a2ff45` |
| `DifferentialHarnessTests.swift` | `df67b84a60245e8356c046931d88cea57268652332297e6ec27792e5aa4252ed` |
| `FaithfulParityReplayEngine.swift` | `10e95fb8afe0594ced08b233bcf8e02dd8622580f0687108e3c02da8a3d5f49f` |
| `FullParityRegressionTests.swift` | `673de278806f6bbbc756597e754cdc2b622d82188f77ca9ae75fa5db36546c12` |
| `NativeExtensionsTests.swift` | `910adbf881fc55d2b41351f1a09f1675c12b1563ce96254b388056bd266cdf12` |
| `NativeIntegrationTests.swift` | `2f52da6a9532e47b13c8a3e2de97329ed66351d66d362a7aa6f7890578e5cfe8` |
| `NumericKernelsTests.swift` | `7c606a402a6d6bded8d34146d46fc454e27a476be9c256f36dea61c67302cda2` |
| `ParityComparator.swift` | `20247eae8c3d813b87e6b0c58a265a08be4be5c3e6993c26926a81aa5cb32d46` |
| `ParityCorpus.swift` | `79ee0f1879365a5f43e97b7623279827ed3d6ea6563a3e9155c62f4380ee185f` |
| `ParityLoader.swift` | `f2004c7bf037cba48002c627ba7cb8aef622745d44c3aaa0e795bc0ed88e1ade` |
| `ParityModels.swift` | `edb80b0224c03ee39d8a659f012db8f32f8ad4b69a50433e414435b53821af60` |
| `ParityReplayEngine.swift` | `ee12f55eccfe50619c3658a6fcdce5006b8e2de61d7a05e1c4accc446e662daa` |
| `PublicationAdapterTests.swift` | `47ba0b5b7562db96c2a0df409474d34d048bd8091852dd24aeba1f6ec0769f44` |
| `StatelessDetectorTests.swift` | `13d538bb37ce72d04be9be7a5517efbb3a2740fb2646fcc5fcf0c9fe9f5e5439` |
| `StreamingDetectorTests.swift` | `abbc689c3229f3ac4677125c36988b2c9044031798cf1540fa90310336159a46` |
| `TargetTrackerTests.swift` | `6fbafcdba8456021a59b58eefd9447c4748be0899c55a82f19cb4e4e46d4da9b` |
| `TrackerMotionTests.swift` | `4203e6ef358fe8744e9ad04c63fb82ceb67ed18ccb6b2fd86cb9823a693eac89` |

### 2.4 Frozen Parity Manifest (`Tools/parity-contract/schema/manifest.json`)
- **SHA-256:** `4d2ab7c4bdd84cd3a8e6d706759636e72e3c9fee9c9e9c435497263f89e0b2bd`

---

## 3. Reproduction Commands

All results are fully reproducible via standard makefile targets:

```bash
# 1. Verify TypeScript contract, reference source hashes, and trace reproducibility:
make verify-parity

# 2. Regenerate Xcode project configuration from project.yml:
make project

# 3. Execute all unit, integration, and full-stream parity regression suites:
make test
```

---

## 4. Corpus Coverage & Case Breakdown

| Category | Cases | Frames | Description / Invariants Tested |
| :--- | :--- | :--- | :--- |
| `product-fixtures` | 17 | 3,425 | Real recorded acoustic instruments (ukulele plucks, guitar notes, multi-strum sessions, background noise). |
| `controlled-44100` | 19 | 2,052 | Synthetic standard tuning plucks @ 44.1 kHz, known frequencies, decays, inharmonicity. |
| `controlled-48000` | 19 | 2,052 | Synthetic standard tuning plucks @ 48.0 kHz, exact 1000/1024 hop cadence testing. |
| `stress-standard` | 96 | 10,368 | Standard harmonic series across pitch, decay, noise levels (0.0 to 0.05), SNR variations. |
| `stress-odd` | 96 | 10,368 | Odd harmonic series (clarinet/closed-pipe profile), evaluating octave confusion resilience. |
| `targeted` | 35 | 3,230 | Critical edge conditions: 96 kHz capture, total silence, NaN/Inf degenerate vectors, state reset sequences, 3/8/12/15-cent steps, continuous sweeps, quiet onset, anti-alias boundaries. |
| **Total** | **282** | **31,495** | **100% Corpus Pass Rate** |

---

## 5. Numeric Budgets & Observed Precision

| Metric / Field | Frozen Budget | Worst Observed Delta | Margin to Budget | Status |
| :--- | :--- | :--- | :--- | :--- |
| Detector Frequency | `1.0e-4 Hz` | `0.0 Hz` | Complete bit-identical match | PASSED |
| Raw Cents | `1.0e-4 cents` | `0.0 cents` | Complete bit-identical match | PASSED |
| Smoothed Cents | `1.0e-4 cents` | `0.0 cents` | Complete bit-identical match | PASSED |
| Confidence | `1.0e-6` | `0.0` | Complete bit-identical match | PASSED |
| RMS Absolute | `1.0e-7` | `0.0` | Complete bit-identical match | PASSED |
| RMS Relative | `1.0e-4` | `0.0` | Complete bit-identical match | PASSED |
| Sample Timestamp | `1.0e-6 ms` | `0.0 ms` | Exact sample-clock match | PASSED |

---

## 6. Native Regression & Investigation Review

All native suites running under `make test` were evaluated and reconciled:
1. **Preservation of Existing Investigations:**
   - `CrossEngineComparisonTests.swift`: Kept historical trace emitter without requiring external WASM dependencies.
   - `CoverageMatrixTests.swift`: Historical polyphonic and semitone defeat demonstrations preserved.
   - `RealStrumMeasurementTests.swift`: Retained baseline measurements on real recorded strum fixtures.
   - `SustainContinuityTests.swift`: Verifies sustained plucks and dropout resilience.
2. **Native Extensions & Architectural Invariants:**
   - Single-owner generation and hold state isolated to `FaithfulPresentation` and `TunerAnalysisSession`.
   - Audio capture framing respects 4096-sample windowing on 1024-sample hops with bounded capacity-1 mailbox.
   - Reference tone interruption strictly stops capture and flushes buffered audio to prevent self-confirmation.
3. **Zero Unexpected Regressions:**
   - No changed expectations or weakened comparison assertions across any native suite.

---

## 7. Negative Controls Verification

Negative controls were executed within `DifferentialHarnessTests` and `FullParityRegressionTests` to confirm test sensitivity:
1. **Altered Hop Cadence:** Shifting sample index by 128 samples fails comparison immediately.
2. **Lost Confirmation:** Clearing confirmation flags fails comparison immediately.
3. **Threshold Violations:** Perturbing cents by `> 1e-4` or frequency by `> 1e-4` triggers comparator errors.
4. **RMS Budget Exceedance:** Modifying RMS values beyond compound budget is detected.
5. **Null Mask Inversion:** Emitting frequency on silent frames or nulling valid detection triggers discrete mismatch errors.
6. **Non-Finite Detection:** Injecting NaN or Infinity into numeric fields triggers explicit validation failures.

---

## 8. Explicit Outstanding Device Work (Ticket 13 Hand-Off)

Offline algorithmic and framewise trace parity is 100% verified. In accordance with the project specification and Ticket 13 (`13-device-release-acceptance.md`), the following physical device validation items remain outstanding for human execution:

1. **Hardware Profile & OS Verification:**
   - Physical iPhone execution under intended Release configuration (`-O`).
   - Benchmarking capture-to-publication latency against the 1024/sampleRate (~23.2 ms @ 44.1k / 21.3 ms @ 48k) processing deadline.
2. **Sustained System Resource Profiling:**
   - Measure CPU usage, thermal state, and memory allocations over extended (10+ minute) tuning sessions.
   - Verify zero dropped algorithm windows under sustained acoustic input.
3. **Acoustic & Microphone Ergonomics:**
   - Test with physical guitar and ukulele instruments across quiet plucks, noisy environments, and rapid peg adjustments.
   - Verify physical speaker-to-microphone isolation during reference tone playback on hardware speakers.
4. **Final Release Asset Audit:**
   - Verify App Store submission archive contains zero test oracles, fixtures, or debug tools.

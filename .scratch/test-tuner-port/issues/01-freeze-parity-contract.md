# 01 — Freeze the reference and same-input parity contract

Status: resolved
Blocked by: none (completed)

## Outcome
Make “same algorithm” reproducible without a sibling checkout or external tuner.
Use [the spec](../spec.md) as authority; do not regenerate expected outputs from Swift.

## Work and test boundary
- [x] Pin source commit/hashes and default construction paths; record provenance and
  permitted own-source licensing. Store a test-only source snapshot or a reproducible
  pinned extraction with durable corpus artifacts; no moving branch dependency.
- [x] Export own-code-only PCM and golden traces: detector, tracker, publication and
  confirmation events. Record nulls, optional flags, raw and smoothed cents, all RMS
  meanings, target/string identity, sample index, config and reset events.
- [x] Inventory all 55 product cases, both 96-case stress matrices and targeted tests
  named in the spec; distinguish oracle-only generation from external comparison tools.
- [x] Decode files once into canonical Float32 PCM; hash bytes. Inventory both repos'
  recordings independently: equal names do not mean equal PCM. Include native fixtures.
- [x] Freeze numeric budgets/schema, near-threshold vectors and worklet versus
  window-end timestamp conventions. Report any empirically necessary contract change
  for review before accepting Swift output; exact discrete decisions remain mandatory.
- [x] Include 44.1/48/96 kHz, silence, invalid/short data, rate changes, reset events,
  duplicate targets, gaps, quiet onset, alias interference and 3–15-cent movement.
- [x] Add a clean-checkout reproducibility check and verify test/oracle files are
  excluded from the app bundle/project resources.

## Acceptance
Two exports from the pinned own-code source produce the same canonical trace data
and hashes (volatile metadata excluded explicitly). No native parity claimed yet.
Every input/expected trace has provenance; missing cases fail inventory validation.

## Comments
- Pinned reference authority commit: `6a5a4f30304f392ff9dec9997633f83c295e1e1b` (author: Wojciech Urbański <wojtiku@gmail.com>).
- Source snapshot stored in `Tools/parity-contract/reference-source/` with exact SHA-256 byte matches for all 7 files:
  - `pitch.ts`: `009c7b4c357fe729012da21394c69e433264a525b6c0e38216e3fb7bd7ca4fe1`
  - `spectrum.ts`: `90c67aec8cf7769380da5dfb93d95a1b61725feb9fcfc814b0a7b022e57b1b81`
  - `tuning.ts`: `a744f4cc7033e885b2d48608b1e9327e4fb22606a781be1de2870f3de9aa83ff`
  - `audio-worklet.ts`: `99e5390bee0d655ee2a30c02b9dbf0594bb1202843e7573421f7e04a6a340f9c`
  - `presentation.ts`: `f16d7bc502a6350e6a4db29b542621174acd652ad7db75fe0eca6767ba0bcc0f`
  - `feedback.ts`: `5b90171a9e113c12cdcbaa0243dd4a5260036e52c550476d6ae28c714cab5ab1`
  - `main.ts`: `dd31f09b268ac673abef9cba337a032caaec0799975c4fa3fe372f307ec322b7`
- Provenance and licensing recorded in `Tools/parity-contract/reference-source/PROVENANCE.md`.
- Pinned corpus and canonical decoded PCM stored in `Tools/parity-contract/corpus/fixtures/` and `decoded/`.
- Machine-readable parity manifest frozen at `Tools/parity-contract/schema/manifest.json`.
  - Numeric budgets: Frequency 1e-6 Hz, Raw/Smoothed cents 1e-6, Confidence 1e-9, RMS 1e-10 abs + 1e-7 rel, Sample index exact, Timestamp conversion <= 1e-6 ms.
  - Discrete rules: Null mask, target note/index, publication slot, inTune transitions, and confirmation events must match exactly.
  - Full inventory: 282 cases total, 31,495 frames across:
    - 55 product cases (17 fixture recordings + 19 controlled @ 44.1 kHz + 19 controlled @ 48 kHz).
    - 192 stress cases (96 standard harmonics + 96 odd harmonics matrices across 44.1/48 kHz).
    - 35 targeted cases (44.1/48/96 kHz, silence/subthreshold, degenerate/short/NaN/Inf/DC offset, mid-stream resets, slack duplicate targets, short/medium/long gaps, quiet onset bootstrap, alias interference, 3-15c steps, boundary conditions).
- Golden traces stored per case in `Tools/parity-contract/traces/<category>/<case-name>.json`.
- Verification tool implemented in `Tools/parity-contract/verify.ts` and wired into `make verify-parity`. It re-runs the entire export in memory, confirms bit-identical trace hashes, and verifies that `project.yml` strictly excludes test/oracle files from the `StrumKit` app bundle target.
- All existing StrumKit unit tests (`make test`) pass without warnings or regressions.

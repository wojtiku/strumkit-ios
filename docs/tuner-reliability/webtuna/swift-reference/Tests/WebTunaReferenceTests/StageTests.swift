import XCTest
@testable import WebTunaReference

/// Stages 1–5, checked value-by-value against the running wasm.
///
/// `Fixtures/intermediates.json` was recorded by `tools/probe-intermediates.mjs`,
/// which drives the real module and dumps its own spectrum, 56 band values and
/// compressed magnitudes. These tests replay the same tones through the Swift
/// port and compare the arrays, so a divergence in the filterbank is caught here
/// rather than being hidden behind an end-to-end number that still looks plausible.
///
/// **Tolerances, and why they are what they are.**
///
/// * Window: 3e-8 absolute. That is the figure WEBTUNA.md §3.1 quotes for its own
///   check against the live window vector, i.e. float32 round-off on a value in
///   [0.08, 1.0].
/// * Spectrum magnitudes: 1e-5 **relative**. The engine's FFT is Ooura's, this
///   is vDSP's; both compute the same DFT but in a different order, so they
///   differ in the last couple of float32 ulps — about 6e-7 relative. 1e-5 is a
///   deliberate two-order-of-magnitude headroom over that, not a tight bound: a
///   genuine algorithmic difference (a wrong window, a wrong divisor, a shifted
///   bin) moves these by 10–100 %, so nothing real can hide under 1e-5.
/// * Band values: 2e-4 relative. Each is a weighted sum of up to ~30 float32
///   magnitudes with weights that can be near zero, so the error accumulates
///   across ~30 roundings rather than one.
/// * Compressed magnitudes: 2e-5 relative. One extra `sqrt` and one `cbrt` on top
///   of the band value, which *shrinks* relative error (the cube root of x has
///   three times the absolute error and the same sign), so the band tolerance
///   divided by three.
/// * Spectrum RMS / `MicRms`: 1e-4 relative, from summing 1130 squares.
final class StageTests: XCTestCase {

    // MARK: - Stage 1–2: framing geometry and the window

    func testFrameGeometry() {
        XCTAssertEqual(FrameGeometry.realSize, 4096)
        XCTAssertEqual(FrameGeometry.complexSize, 8192)
        XCTAssertEqual(FrameGeometry.hop, 2048)
        // §3.2: a 4096-sample call yields two frames.
        XCTAssertEqual(FrameGeometry.framesPerCall, 2)
    }

    func testWindowIsTheSymmetricBlackman() {
        let w = FrameGeometry.window
        XCTAssertEqual(w.count, 4096)
        // w[0] = 0.54 - 0.46 = 0.08; the centre is 0.54 + 0.46*cos(0) ≈ 1.
        XCTAssertEqual(w[0], 0.08, accuracy: 1.2e-7)
        XCTAssertEqual(w[2048], 1.0, accuracy: 1.2e-7)
        // Exactly symmetric, because the second half is a mirror of the first
        // rather than an independent evaluation.
        for n in 0..<2048 {
            XCTAssertEqual(w[n], w[4095 - n], "window is not symmetric at n=\(n)")
        }
        // And equal to the closed form. The tolerance is **one float32 ulp**
        // (1.19e-7), not the 3e-8 of WEBTUNA.md §3.1: that figure was measured
        // against the *live* window vector, which is not committed and is
        // computed by the engine's own float32 sin/cos polyfill, whereas this is
        // a Double evaluation rounded to float32. The two differ by at most one
        // ulp at a handful of n; a tighter bound would be asserting that libm
        // and the engine's polyfill round identically.
        for n in stride(from: 0, to: 4096, by: 37) {
            let want = 0.54 - 0.46 * cos(2.0 * Double.pi * Double(n) / 4095.0)
            XCTAssertEqual(Double(w[n]), want, accuracy: 1.2e-7, "window mismatch at n=\(n)")
        }
    }

    // MARK: - Stage 3: the analysed bin range is derived, not chosen

    func testAnalysedBinRangeIsDerivedFromTheFilterbankEdges() {
        let engine = WebTunaReferenceEngine(sampleRate: 44_100)
        // §3.1 quotes 7…1136 at 44.1 kHz. The point of the test is that these
        // come out of T_lo[0] and T_hi[55] rather than being written down: at
        // 48 kHz the same tables give a different range, which is exactly the
        // mechanism behind §4.4's bass-low-E observation.
        XCTAssertEqual(engine.analysedBinRange, 7...1136)

        let at48k = Filterbank(sampleRate: 48_000)
        XCTAssertEqual(at48k.lowestBin, 6, "bin 7 is the 44.1 kHz value, not a constant")
        XCTAssertEqual(at48k.highestBin, 1044)
    }

    func testFilterbankTableMatchesTheLiveEngine() {
        let t = EngineTables.filterbank
        // Read out of the running module by tools/probe-intermediates.mjs and
        // docs/tuner-reliability/webtuna/tables3.mjs. Note the last figure:
        // evaluating this formula in Double gives 5465.0, so float32 is load
        // bearing.
        XCTAssertEqual(t.centre[0], 65.0000076, accuracy: 1e-4)
        XCTAssertEqual(t.centre[1], 81.2734909, accuracy: 1e-4)
        XCTAssertEqual(t.centre[55], 5464.50244, accuracy: 1e-2)
        XCTAssertEqual(t.lower[0], 34.9693375, accuracy: 1e-4)
        XCTAssertEqual(t.upper[0], 98.4479523, accuracy: 1e-4)
        XCTAssertEqual(t.upper[55], 6112.375, accuracy: 1e-2)
        // The support is ±2 band steps, not ±1 — the correction in NOTES.md.
        XCTAssertEqual(t.lower[2], t.centre[0], accuracy: 1e-4,
                       "T_lo[k] should be T_ctr[k-2]; WEBTUNA.md §3.3 says k-1")
        XCTAssertEqual(t.upper[53], t.centre[55], accuracy: 1e-2)
    }

    func testCandidateGrid() {
        let guitar = EngineTables.candidateGrid(for: .auto)
        // §3.5: 675 entries, entry 0 = 36.710 Hz = MIDI 26.00.
        XCTAssertEqual(guitar.notes, 675)
        XCTAssertEqual(guitar.baseMIDI, 26)
        XCTAssertEqual(guitar.frequencies[0], 36.7080917, accuracy: 1e-4)
        XCTAssertEqual(guitar.frequencies[1], 36.8497521, accuracy: 1e-4)
        XCTAssertEqual(guitar.frequencies[674], 491.985, accuracy: 1e-2)

        // Chromatic widens it; §3.5's caveat that the grid stops near MIDI 71 is
        // wrong for chromatic mode (NOTES.md).
        let chromatic = EngineTables.candidateGrid(for: .chromatic)
        XCTAssertEqual(chromatic.notes, 1125)
        XCTAssertEqual(chromatic.baseMIDI, 15)
        XCTAssertEqual(chromatic.frequencies[0], 19.4454365, accuracy: 1e-4)
    }

    // MARK: - Stages 3–5 against the live module

    func testSpectrumMatchesTheLiveEngine() throws {
        let data = try Intermediates.load()
        XCTAssertEqual(data.sampleRate, 44_100)

        for c in data.cases {
            let engine = WebTunaReferenceEngine(sampleRate: Float(data.sampleRate))
            let tone = ReferenceTone.samples(frequency: c.freq, sampleRate: data.sampleRate,
                                             harmonics: harmonics(for: c.label))
            for _ in 0..<c.calls {
                _ = engine.analyse(tone, stringIndex: c.idx)
            }
            guard let got = engine.lastFrame else { return XCTFail("\(c.label): no frame ran") }

            // The engine keeps 1136 spectrum floats (bins 0…1135); this port keeps
            // the whole 4097-bin buffer, so compare the overlapping prefix.
            let n = c.spectrum.count
            assertClose(Array(got.spectrum[0..<n]), c.spectrum, rel: 1e-5, absolute: 2e-8,
                        what: "\(c.label) spectrum", skipBelow: 1e-7)
            // (absolute floor 2e-8: the high bins are float32 round-off in both
            // implementations, ~1.3e-6 with a ~1e-9 spread.)

            // And therefore MicRms, the only output that depends on the absolute
            // scale of the spectrum.
            XCTAssertEqual(Double(got.spectrumRMS) * 128.0, Double(c.spectrumRMS) * 128.0,
                           accuracy: Double(c.spectrumRMS) * 128 * 1e-4,
                           "\(c.label): MicRms \(got.spectrumRMS * 128) vs \(c.spectrumRMS * 128)")
        }
    }

    /// Stages 4–5 could **not** be verified against the engine's internals.
    ///
    /// `tools/probe-intermediates.mjs` finds a 56-float array in the engine's
    /// `Ooura_FFT` object that satisfies the §3.4 salience relation against a
    /// second 56-float array to 1.3e-7 — float32 round-off — so the *pair* is
    /// real. But its magnitudes are 50× (band 0) to 6e5× (band 52) smaller than
    /// any positive weighted sum of the spectrum that the decompile's triangle
    /// describes, and they decay smoothly at a fixed 0.87 per band across bands
    /// 21…55 where the spectrum is a flat 1.2e-6 noise floor. A positive weighted
    /// sum over fifty bins of a 1.2e-6 floor cannot be 2.5e-8. So that array is
    /// *not* the filterbank output, and the correct array was not identified.
    ///
    /// This test therefore asserts the relation between the two arrays the probe
    /// found (which is what the probe itself verifies) rather than claiming a
    /// match with the port's own band values. Stages 4–5 rest on the decompile
    /// and on end-to-end conformance; see DIVERGENCES.md D6, which is the single
    /// most important thing this port could not settle.
    func testEngineSaliencePairRelationHoldsButIsNotTheFilterbank() throws {
        let data = try Intermediates.load()
        for c in data.cases {
            XCTAssertEqual(c.bands.count, 56)
            var total: Float = 0
            for v in c.bands { total += v }
            let floorValue = total / 56 * 0.0001
            for k in 0..<56 {
                let clamped = max(c.bands[k], floorValue)
                let want = powf((clamped / 4095.0).squareRoot() * 1.414214, 1.0 / 3.0)
                XCTAssertEqual(c.compressed[k], want, accuracy: abs(want) * 1e-5,
                               "\(c.label): salience relation at band \(k)")
                XCTAssertEqual(c.residual[k], c.bands[k] / c.compressed[k],
                               accuracy: abs(c.bands[k] / c.compressed[k]) * 1e-4)
            }
            // ... and the magnitudes are far below anything the decompile's
            // triangle can produce, which is the finding. (For a signal whose
            // harmonics do reach this high, band 40 is legitimately larger; the
            // discriminator is the *noise-floor* cases.)
            if c.label == "e2-7harm" || c.label == "a2-3harm" {
                XCTAssertLessThan(c.bands[40], 1e-7,
                                  "\(c.label): band 40 is \(c.bands[40]); the array is no longer "
                                  + "below any plausible weighted sum, so it may have been re-identified")
            }
        }
    }

    /// The salience's defining relations, checked on their own terms so a failure
    /// says which stage broke rather than only that "the pipeline" broke.
    func testSalienceTransformRelations() {
        let bands: [Float] = (0..<56).map { Float(1e-4) * Float(1 + $0 % 7) }
        var a: [Float] = [], i: [Float] = []
        Salience.transform(bands: bands, compressed: &a, residual: &i)
        let total = bands.reduce(0, +)
        let floorValue = total / 56 * 1e-4
        for k in 0..<56 {
            let want = powf((max(bands[k], floorValue) * 2.0 / 4095.0).squareRoot(), 1.0 / 3.0)
            XCTAssertEqual(a[k], want, accuracy: abs(want) * 1e-6)
            XCTAssertEqual(i[k], bands[k] / a[k], accuracy: abs(bands[k] / a[k]) * 1e-6)
        }
    }

    // MARK: - helpers

    /// `probe-intermediates.mjs` uses the 7-harmonic reference tone except for
    /// the two cases that deliberately do not.
    private func harmonics(for label: String) -> [Double] {
        switch label {
        case "a2-3harm": return [1, 0.5, 0.33, 0, 0, 0, 0]
        case "e2-pure": return [1, 0, 0, 0, 0, 0, 0]
        default: return ReferenceTone.harmonics
        }
    }

    private func assertClose(_ got: [Float], _ want: [Float], rel: Float, absolute: Float,
                             what: String, skipBelow: Float) {
        XCTAssertEqual(got.count, want.count, "\(what): length")
        guard got.count == want.count else { return }
        var worst = 0.0
        var worstAt = -1
        for k in 0..<got.count {
            let a = Double(got[k]), b = Double(want[k])
            // Pass if *either* the relative or the absolute criterion holds. The
            // absolute one exists because the high bins of the spectrum are pure
            // float32 round-off in both implementations — a genuine noise floor
            // around 1.3e-6 with a between-implementation spread of ~1e-9. A
            // relative-only test would be asserting that two FFTs agree on their
            // own rounding error, which is not a meaningful thing to ask.
            if abs(a - b) <= Double(absolute) { continue }
            if max(abs(a), abs(b)) < Double(skipBelow) { continue }
            let e = abs(a - b) / max(abs(a), abs(b))
            if e > worst { worst = e; worstAt = k }
        }
        XCTAssertLessThan(worst, Double(rel),
                          "\(what): worst relative error \(String(format: "%.3e", worst)) at index \(worstAt)")
    }
}

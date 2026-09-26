import Foundation

/// The port of GuitarTuna's `WebTuna.wasm` pitch engine.
///
/// **This is not a proposed change to StrumKit.** It is a standalone reference
/// implementation of somebody else's algorithm, kept so that the reverse
/// engineering in `docs/tuner-reliability/WEBTUNA.md` can be checked rather than
/// believed, and so that experiments ("swap a constant, see what breaks") have
/// somewhere to run. Nothing here is imported by StrumKit and nothing here
/// should be.
///
/// Usage mirrors the wasm exactly — the ABI is a hard 4096-sample call:
///
///     let engine = WebTunaReferenceEngine(sampleRate: 44_100)
///     var result = WebTunaResult.stub
///     var s = 0
///     while s + 4096 <= audio.count {
///         result = engine.analyse(Array(audio[s..<s + 4096]), stringIndex: -1)
///         s += 4096
///     }
///
/// The first two calls always return `CanHearANote == false` (§4.2).
public final class WebTunaReferenceEngine {
    public let sampleRate: Float
    public let tuning: Tuning
    public private(set) var state = DetectorState()

    private let filterbank: Filterbank
    private let spectrumAnalyser: SpectrumAnalyser
    private var grid: EngineTables.CandidateGrid
    private var lastMode: Tuning.Mode?

    // Per-frame scratch, reused to keep the reference implementation allocation
    // free on the hot path. A reference port is allowed this; it is not an
    // optimisation that changes behaviour.
    private var frame = [Float](repeating: 0, count: FrameGeometry.realSize)
    private var spectrum = [Float](repeating: 0, count: FrameGeometry.complexSize / 2)
    private var bandValues = [Float](repeating: 0, count: Filterbank.bandCount)
    private var compressed = [Float](repeating: 0, count: Filterbank.bandCount)
    private var residual = [Float](repeating: 0, count: Filterbank.bandCount)
    private var salience: [Float] = []
    private var scores: [Float] = []
    /// The current frame's stage-6 output. Held so `decide` and the tests can read
    /// it without recomputing.
    private var analysis: CandidateAnalysis?

    public init(sampleRate: Float = 44_100, tuning: Tuning = .guitar) {
        self.sampleRate = sampleRate
        self.tuning = tuning
        self.filterbank = Filterbank(sampleRate: sampleRate)
        self.spectrumAnalyser = SpectrumAnalyser(sampleRate: sampleRate)
        self.grid = EngineTables.candidateGrid(for: .auto, tuning: tuning)
    }

    /// The mode the engine last ran in, and the derived bin range. Exposed so the
    /// stage tests can assert on §3.1's "bins 7…1136" without re-deriving it.
    public var analysedBinRange: ClosedRange<Int> {
        filterbank.lowestBin...filterbank.highestBin
    }

    /// The last frame's stages 3–5, captured for the stage tests. The wasm never
    /// reports these, so they are compared against `Fixtures/intermediates.json`
    /// (recorded by `tools/probe-intermediates.mjs`) instead of against the JSON
    /// output. `nil` until the first frame has run.
    public private(set) var lastFrame: (spectrum: [Float], bands: [Float],
                                        compressed: [Float], residual: [Float],
                                        spectrumRMS: Float)?

    // MARK: - The API

    /// One `analyseBuffer` call: exactly `FrameGeometry.callSize` samples, the
    /// `stringIdx` of §1.3, and the sample rate.
    public func analyse(_ samples: [Float], stringIndex: Int32) -> WebTunaResult {
        precondition(samples.count == FrameGeometry.callSize,
                     "analyseBuffer is a fixed \(FrameGeometry.callSize)-sample call (§1.1)")
        let mode = Tuning.mode(forStringIndex: stringIndex)
        if mode != lastMode {
            applyMode(mode)
            lastMode = mode
        }

        // §3.2: walk the input one sample at a time into the ring; whenever the
        // write cursor reaches 4096, run a frame and rewind to 2048. A
        // 4096-sample call therefore runs exactly two frames.
        for v in samples {
            state.ring[state.writeCursor] = v
            state.writeCursor += 1
            if state.writeCursor == FrameGeometry.realSize {
                state.writeCursor = FrameGeometry.hop
                runFrame()
                // The ring is a *linear* buffer that gets shifted, not a circular
                // one. The decompile does `memory_copy(ring, ring + hop,
                // (realSize - hop) * 4)` immediately after the frame; without it
                // the second frame would read a window that is half stale.
                shiftRing()
            }
        }

        return makeResult()
    }

    private func shiftRing() {
        let n = FrameGeometry.realSize, hop = FrameGeometry.hop
        state.ring.withUnsafeMutableBufferPointer { buf in
            memmove(buf.baseAddress!, buf.baseAddress! + hop, (n - hop) * MemoryLayout<Float>.size)
            for i in (n - hop)..<n { buf[i] = 0 }
        }
    }

    // MARK: - Mode changes (§1.3, §4.6)

    private func applyMode(_ mode: Tuning.Mode) {
        state.stringIndex = mode.requestedString.map(Int32.init) ?? (mode == .chromatic ? -2 : -1)
        // Switching mode resets the confidence counter and the agreement run, but
        // *not* the reported pitch — §4.6 notes `MeasuredPitchHz` is never
        // cleared, and the decompile only clears it on a string change.
        state.inTuneCount = 0
        state.agreeCount = 0
        state.noteLatched = false
        if case .string(let i) = mode {
            state.targetString = i
        } else if case .chromatic = mode {
            state.targetString = 0
        } else {
            state.targetString = -1
        }
        grid = EngineTables.candidateGrid(for: mode, tuning: tuning)
        salience = []
        scores = []
        analysis = nil
    }

    // MARK: - One analysis frame (§3.2 onwards)

    private func runFrame() {
        let rms = spectrumAnalyser.analyse(frame: state.ring, into: &spectrum)

        // §3.8: MicRms is a hard peak hold over a 64-frame ring — a 2.97 s
        // window, two frames written per call, so it drops to zero in a single
        // step 32 calls after the sound stops (§4.6).
        state.rmsRing[state.rmsCursor] = rms
        state.rmsCursor = (state.rmsCursor + 1) % PitchDecision.rmsRingSize
        var peak: Float = 0
        for v in state.rmsRing { if v > peak { peak = v } }
        state.micRms = peak * PitchDecision.micRmsScale

        filterbank.bands(spectrum: spectrum, into: &bandValues)
        Salience.transform(bands: bandValues, compressed: &compressed, residual: &residual)
        lastFrame = (spectrum, bandValues, compressed, residual, rms)
        analysis = CandidateAnalysis(bands: residual, filterbank: filterbank, grid: grid,
                                     salience: &salience, score: &scores)

        guard let peak = pickPeak() else {
            // No local maximum in the grid: the frame contributes nothing but the
            // level meter, and the confidence counter is reset (§3.7: "It resets
            // to 0 the moment the frame-level in-tune test fails").
            state.inTuneCount = 0
            state.agreeCount = 0
            return
        }
        // §3.6's harmonic-support gate. Recorded on the result so a reader can see
        // how often it fires; it does not veto, for the reason in its doc comment.
        if harmonicSupportHolds(peak) { state.harmonicGatePasses += 1 }
        state.harmonicGateOpportunities += 1
        decide(peak)
    }

    // MARK: - Stage 6: peak picking and the harmonic-support test

    private struct Peak {
        var index: Int
        var frequency: Float
        var salience: Float
        /// The salience at the previous grid entry, i.e. `k[20]`.
        var previous: Float
    }

    /// §3.6: local maxima on the grid **salience**, refined parabolically.
    ///
    /// The peak is chosen on the salience, not on the harmonic score. §3.6 is
    /// explicit ("Local maxima are found on the 56-band salience") and the
    /// distinction is load bearing: the per-harmonic weight contains
    /// `(sr/f + 52)`, which is 2.4x larger at the bottom of the guitar grid
    /// (36.7 Hz) than at E2 (82.4 Hz), so argmax-ing the score locks onto the
    /// lowest grid entry for almost any input. The score is the harmonic-support
    /// measure consulted afterwards, not the selector.
    private func pickPeak() -> Peak? {
        let n = grid.notes
        guard n >= 3 else { return nil }

        // Best salience wins; ties break toward the lower grid index, which is
        // what a strict `>` scan gives.
        var best = -1
        var bestValue: Float = -1
        for d in 1..<(n - 1) where salience[d] > bestValue {
            bestValue = salience[d]
            best = d
        }
        guard best >= 0 else { return nil }

        // The parabolic refinement, gated on |delta| <= 0.5.
        var frequency = grid.frequencies[best]
        let x0 = salience[best - 1], x1 = salience[best], x2 = salience[best + 1]
        if x1 > x0, x1 > x2 {
            let denominator = x0 - 2 * x1 + x2
            if denominator != 0 {
                let delta = (x2 - x0) / denominator
                if abs(delta) <= 0.5 {
                    frequency = grid.frequencies[best]
                        + delta * 0.5 * (grid.frequencies[best + 1] - grid.frequencies[best - 1])
                }
            }
        }

        return Peak(index: best, frequency: frequency, salience: salience[best],
                    previous: salience[max(0, best - 1)])
    }

    /// §3.6's harmonic-support gate, from the decompile:
    ///
    ///     ca = salience[cand] / salience[nextHigherHarmonic] > 2.0
    ///     ca / previous                               > 0.4
    ///     ca > previous + previous
    ///
    /// This is the check that "kills single-spurious-bin locks" (§6): a candidate
    /// whose fundamental is not clearly the loudest thing near it, and is not
    /// clearly louder than what it was last frame, is not a pitch.
    ///
    /// **This is where the port stops matching.** In the decompile these three
    /// tests are the *entry* condition for the "new detection" path, and the
    /// elaborate search that follows runs when they *fail* -- so failing them does
    /// not reject the candidate, it routes it to a continuity search that usually
    /// re-accepts it. The port rejects outright. See DIVERGENCES.md D7.
    private func harmonicSupportHolds(_ peak: Peak) -> Bool {
        let ca = peak.salience
        guard ca > 0 else { return false }
        let next = min(salience.count - 1, peak.index + 1)
        let nextHigher = salience[next]
        let previous = peak.previous
        guard nextHigher > 0, previous > 0 else { return false }
        return (ca / nextHigher) > 2.0 && (ca / previous) > 0.4 && ca > previous + previous
    }

    // MARK: - Stage 7: the state machine

    private func decide(_ peak: Peak) {
        // The per-string cent tolerance (§3.6, read live as 7,7,10,7,7,12), or
        // chromatic mode's own 10-cent gate.
        let isChromatic = state.stringIndex == -2
        if isChromatic {
            state.targetString = 0
        } else if state.targetString < 0 || state.targetString >= tuning.stringHz.count {
            // Auto: the engine commits to the string whose frequency the detected
            // pitch is nearest, and keeps that string for the cents, the tolerance
            // and `CurrentString`. (Reporting string 0 unconditionally in auto mode
            // costs 100 % of `CurrentString` agreement — measured.)
            state.targetString = nearestStringIndex(to: peak.frequency)
        }
        let target = tuning.stringHz[min(max(state.targetString, 0), tuning.stringHz.count - 1)]
        let tolerance = isChromatic ? PitchDecision.chromaticCents
                                   : tuning.toleranceCents[min(max(state.targetString, 0), 5)]
        state.reportedString = state.targetString

        // §3.6: the ±350 ¢ continuity gate, and the 70 ¢ second gate. Both are
        // relative to the currently smoothed pitch, so neither can apply to the
        // very first detection — there is nothing to be continuous with. (Treating
        // "no prior pitch" as infinite distance rejects every first frame and the
        // detector never starts.)
        if state.smoothedPitch > 0, state.smoothedPitch.isFinite {
            let continuity = abs(cents(fromRatio: peak.frequency / state.smoothedPitch))
            if continuity > PitchDecision.continuityCents {
                // Too far from where we already are: reject the frame outright.
                state.inTuneCount = 0
                state.agreeCount = 0
                state.noteLatched = false
                state.stability = 0
                return
            }
        }

        // §3.6: 0.75/0.25 EMA on the pitch.
        if state.smoothedPitch == 0 || !state.smoothedPitch.isFinite {
            state.smoothedPitch = peak.frequency
        } else {
            state.smoothedPitch = state.smoothedPitch * PitchDecision.emaOld
                                + peak.frequency * PitchDecision.emaNew
        }

        // The stability counter saturates at 17 and decays by 1 or 2 when the
        // frame does not agree.
        let error = cents(fromRatio: peak.frequency / max(1.0, target))
        let agrees = abs(error) <= tolerance
        if agrees {
            state.stability = min(PitchDecision.stabilityCap, state.stability + 1)
            state.agreeCount = min(state.agreeCount + 1, PitchDecision.latchThreshold + 1)
        } else {
            state.stability = 0
            state.agreeCount = 0
        }
        if state.agreeCount >= PitchDecision.latchThreshold {
            state.noteLatched = true
            state.stableString = state.reportedString
        }

        // Push into the 7-entry ring; `InTuneRatio` is computed from its mode, so
        // the ring is what supplies the "agreeing" notion rather than a single
        // frame.
        state.pitchRing[state.pitchRingCursor] = state.smoothedPitch
        state.pitchRingCursor = (state.pitchRingCursor + 1) % PitchDecision.pitchRingSize

        // §3.7: advance the counter at most once per call, by 1 normally and by
        // `agreeCount + 1` on the frame that first flags the note.
        if agrees {
            if !state.noteLatched { state.noteLatched = true }
            state.inTuneCount = min(PitchDecision.ratioDenominator, state.inTuneCount + 1)
        } else {
            state.inTuneCount = 0
        }

        // The reported pitch: the engine keeps it after the note stops (§4.6).
        state.pitchReport = state.smoothedPitch
        state.reportedPitchSmoothed = state.reportedPitchSmoothed == 0
            ? state.pitchReport
            : state.reportedPitchSmoothed * 0.5 + state.pitchReport * 0.5
        state.reportedPitch = state.noteLatched ? state.reportedPitchSmoothed : state.reportedPitch
        state.clampedPitch = min(10000.0, max(10.0, state.reportedPitch))
    }

    private func nearestStringIndex(to frequency: Float) -> Int {
        var best = 0
        var bestCents = Float.greatestFiniteMagnitude
        for (i, f) in tuning.stringHz.enumerated() {
            let c = abs(cents(fromRatio: frequency / f))
            if c < bestCents { bestCents = c; best = i }
        }
        return best
    }

    // MARK: - Stage 8: the result

    private func makeResult() -> WebTunaResult {
        let pitch = state.reportedPitch
        // `MicRms` is live from the first frame on: the level meter does not
        // depend on having heard a note, and the oracle reports 0.1747 on calls 0
        // and 1 while `MeasuredPitchHz` is still 0. Only the pitch-derived fields
        // take the cold-start value, and `MeasuredPitchMidi` clamps to -48
        // because log2(0) is -inf.
        guard pitch > 0, pitch.isFinite else {
            var cold = WebTunaResult.stub
            cold.micRms = Double(state.micRms)
            return cold
        }

        // `MeasuredPitchHz` is `rint` (round-half-to-even) of the reported pitch,
        // not `floor` — see DIVERGENCES.md D1. At E2 one Hz is 21 cents either
        // way, so §5.1's "±21 ¢ of quantisation" halves to ±10.5 ¢.
        let hz = Double(pitch.rounded())
        let clamped = max(10.0, min(10000.0, pitch))
        let midi = min(175, max(-48, Int((12.0 * log2(Double(clamped) / 440.0) + 69.0).rounded())))
        // `TuningErrorCents` *is* `floor`, of the cents error against the target.
        let centsError = Double(Int(cents(fromRatio: clamped / max(1.0, targetFrequency())).rounded(.down)))
        return WebTunaResult(
            canHearANote: state.noteLatched && state.stableString != -1,
            currentString: state.noteLatched ? state.reportedString : -1,
            inTuneRatio: Double(state.inTuneCount) / Double(PitchDecision.ratioDenominator),
            measuredPitchHz: hz,
            measuredPitchMidi: midi,
            micRms: Double(state.micRms),
            possibleWrongStringId: state.noteLatched ? -1
                : (state.stableString >= 0 ? state.stableString : -1),
            tuningErrorCents: centsError
        )
    }

    private func targetFrequency() -> Float {
        guard state.targetString >= 0, state.targetString < tuning.stringHz.count else {
            // Before anything has been heard there is no committed string; E2 is
            // the only choice that keeps the cents field finite.
            return tuning.stringHz.last ?? 82.4069
        }
        return tuning.stringHz[state.targetString]
    }

    private var centsToTarget: Float { cents(fromRatio: state.clampedPitch / max(1.0, targetFrequency())) }
}

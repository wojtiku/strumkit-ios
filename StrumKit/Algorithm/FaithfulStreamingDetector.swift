// StrumKit/Algorithm/FaithfulStreamingDetector.swift
import Foundation

// MARK: - Helper Functions

/// Checks if two frequencies agree within a given tolerance in cents.
/// Matches `agrees` in reference-source/pitch.ts: `Math.abs(1200 * Math.log2(a / b)) <= cents`.
@inline(__always)
public func agreesPitch(_ a: Double, _ b: Double, cents: Double = 50.0) -> Bool {
    guard a > 0.0, b > 0.0 else { return false }
    return abs(1200.0 * log2(a / b)) <= cents
}

// MARK: - Layer 1: PitchDetectorCore

/// First layer of the faithful streaming pitch detector.
/// Refines onset pitch in the first 5 accepted frames, applies fallback harmonic repair,
/// waveform octave doubling repair, and single-tone precision refinement.
/// Matches `createPitchDetectorCore` in reference-source/pitch.ts lines 144-223.
public final class PitchDetectorCore: @unchecked Sendable {
    public private(set) var accepted: Int = 0
    public private(set) var frames: Int = 0
    public private(set) var anchor: (frequency: Double, time: Double)?
    public private(set) var waveformAnchor: (frequency: Double, time: Double)?
    public private(set) var precisionEvidence: (frequency: Double, first: Double, last: Double)?

    public let ranking: SpectralRanking
    public let repairFallback: Bool
    public let repairWaveform: Bool
    public let refineWeak: Bool
    public let analysis: FaithfulFrameAnalysis

    public init(
        ranking: SpectralRanking = .prominence,
        repairFallback: Bool = true,
        repairWaveform: Bool = true,
        refineWeak: Bool = true,
        analysis: FaithfulFrameAnalysis
    ) {
        self.ranking = ranking
        self.repairFallback = repairFallback
        self.repairWaveform = repairWaveform
        self.refineWeak = refineWeak
        self.analysis = analysis
    }

    /// Resets all internal state for a fresh stream.
    public func reset() {
        accepted = 0
        frames = 0
        anchor = nil
        waveformAnchor = nil
        precisionEvidence = nil
    }

    /// Detects pitch for an incoming audio buffer.
    public func detect(
        input: [Float],
        sampleRate: Double,
        sampleTime: Double? = nil
    ) -> FaithfulPitchCandidate? {
        let time = sampleTime ?? (Double(frames) * Double(FaithfulStreamingDetector.hopSize) / sampleRate * 1000.0)
        frames += 1

        if let a = anchor, time - a.time > 300.0 {
            anchor = nil
        }
        if let wa = waveformAnchor, time - wa.time > 300.0 {
            waveformAnchor = nil
        }

        let pitch = FaithfulStatelessDetector.detectPitch(
            input: input,
            sampleRate: sampleRate,
            ranking: ranking,
            analysis: analysis
        )
        if let p = pitch, p.confidence >= 0.75 {
            accepted += 1
        }
        var result = accepted <= 5
            ? FaithfulStatelessDetector.refineOnsetPitch(input: input, sampleRate: sampleRate, pitch: pitch, analysis: analysis)
            : pitch

        // Repair only a weak spectral fallback that has selected a higher harmonic
        // of a freshly measured fundamental.
        if repairFallback && ranking == .prominence,
           let res = result, res.oddOnly != nil, res.confidence < 0.95,
           let a = anchor, time - a.time <= 64.0 {
            let alternative = FaithfulStatelessDetector.detectPitch(
                input: input,
                sampleRate: sampleRate,
                ranking: .supportedPower,
                analysis: analysis
            )
            let candidate = accepted <= 5
                ? FaithfulStatelessDetector.refineOnsetPitch(input: input, sampleRate: sampleRate, pitch: alternative, analysis: analysis)
                : alternative
            if let cand = candidate, cand.frequency < res.frequency,
               agreesPitch(cand.frequency, a.frequency, cents: 5.0),
               [0.5, 1.0 / 3.0].contains(where: { agreesPitch(cand.frequency, res.frequency * $0, cents: 50.0) }) {
                let peaks = analysis.peaks(input: input, rate: sampleRate)
                func powerAt(_ frequency: Double) -> Double {
                    var maxPower = 0.0
                    for peak in peaks {
                        if abs(peak.frequency - frequency) <= max(1.5, frequency * 0.015) {
                            if peak.power > maxPower { maxPower = peak.power }
                        }
                    }
                    return maxPower
                }
                if powerAt(cand.frequency) > powerAt(res.frequency) {
                    result = cand
                }
            }
        }

        // Strong waveform estimates establish a new anchor; fresh agreeing observations continue it.
        if let res = result {
            if (res.confidence >= 0.95 && res.oddOnly == nil) || (anchor != nil && agreesPitch(res.frequency, anchor!.frequency, cents: 50.0)) {
                anchor = (frequency: res.frequency, time: time)
            }
        }

        // Octave-continuation anchor: waveform repairs must not feed back into spectral fallback decisions.
        if repairWaveform && ranking == .prominence,
           let res = result, res.confidence >= 0.75 && res.confidence < 0.95, res.oddOnly == nil,
           let wa = waveformAnchor, time - wa.time <= 64.0,
           agreesPitch(res.frequency * 2.0, wa.frequency, cents: 20.0) {
            let peaks = analysis.peaks(input: input, rate: sampleRate)
            if let peak = peaks.first, peak.frequency <= 1100.0, peak.prominence >= 50.0,
               agreesPitch(peak.frequency, res.frequency * 2.0, cents: 50.0) {
                let frequency = res.frequency * 2.0
                let lower = peak.frequency / 2.0
                func powerAt(_ hz: Double) -> Double {
                    var maxPower = 0.0
                    for p in peaks {
                        if abs(p.frequency - hz) <= max(1.5, hz * 0.015) {
                            if p.power > maxPower { maxPower = p.power }
                        }
                    }
                    return maxPower
                }
                var unexplained = max(powerAt(res.frequency), powerAt(lower))
                let visibleFundamental = peaks.contains { p in
                    p.prominence >= 15.0 && abs(p.frequency - lower) <= max(1.5, lower * 0.015)
                }
                for harmonic in 1...12 where harmonic % 2 != 0 {
                    unexplained = max(unexplained, powerAt(lower * Double(harmonic)))
                }
                if FaithfulStatelessDetector.validFrequency(frequency, profile: analysis.profile) && !visibleFundamental && unexplained < peak.power * 0.1 &&
                    FaithfulStatelessDetector.filteredPeriodResidual(input: input, sampleRate: sampleRate, frequency: frequency, analysis: analysis) <= 0.35 {
                    var modified = res
                    modified.frequency = frequency
                    result = modified
                }
            }
        }

        if let res = result {
            if (res.confidence >= 0.95 && res.oddOnly == nil) || (waveformAnchor != nil && agreesPitch(res.frequency, waveformAnchor!.frequency, cents: 50.0)) {
                waveformAnchor = (frequency: res.frequency, time: time)
            }
        }

        // Persistent single-tone peak precision refinement.
        guard refineWeak, ranking == .prominence, accepted > 5,
              let res = result, res.confidence >= 0.75 && res.confidence < 0.95, res.oddOnly == nil else {
            precisionEvidence = nil
            return result
        }

        let peaks = analysis.peaks(input: input, rate: sampleRate)
        guard let peak = peaks.first(where: { p in
            FaithfulStatelessDetector.validFrequency(p.frequency, profile: analysis.profile) && p.prominence >= 1000.0 && agreesPitch(p.frequency, res.frequency, cents: 20.0)
        }) else {
            precisionEvidence = nil
            return result
        }

        if FaithfulStatelessDetector.filteredPeriodResidual(input: input, sampleRate: sampleRate, frequency: peak.frequency, analysis: analysis) > 0.5 {
            precisionEvidence = nil
            return result
        }

        let hasConflicting = peaks.contains { p in
            let harmonic = Int(FaithfulSpectralKernels.jsRound(p.frequency / peak.frequency))
            guard harmonic > 0 else { return false }
            let difference = abs(1200.0 * log2(p.frequency / (peak.frequency * Double(harmonic))))
            return p.frequency >= peak.frequency * 0.75 && harmonic <= 8 && p.power >= peak.power * 0.1 && difference > 5.0
        }
        if hasConflicting {
            precisionEvidence = nil
            return result
        }

        if precisionEvidence == nil || time - precisionEvidence!.last > 32.0 || !agreesPitch(peak.frequency, precisionEvidence!.frequency, cents: 5.0) {
            precisionEvidence = (frequency: peak.frequency, first: time, last: time)
        } else {
            precisionEvidence = (frequency: peak.frequency, first: precisionEvidence!.first, last: time)
        }

        if time - precisionEvidence!.first >= 64.0 {
            var modified = res
            modified.frequency = peak.frequency
            return modified
        } else {
            return result
        }
    }

    public func callAsFunction(
        input: [Float],
        sampleRate: Double,
        sampleTime: Double? = nil
    ) -> FaithfulPitchCandidate? {
        detect(input: input, sampleRate: sampleRate, sampleTime: sampleTime)
    }
}

// MARK: - Layer 2: RecoveredPitchDetector

/// Second layer of the faithful streaming pitch detector.
/// Recovers fresh null dropouts using stable single-tone history or paired partial harmonics.
/// Matches `createRecoveredPitchDetector` in reference-source/pitch.ts lines 229-291.
public final class RecoveredPitchDetector: @unchecked Sendable {
    public private(set) var frames: Int = 0
    public private(set) var stableAnchor: (frequency: Double, time: Double)?
    public private(set) var pairedAnchor: (frequency: Double, time: Double)?
    public private(set) var evidence: [(frequency: Double, time: Double)] = []

    public let coreDetector: PitchDetectorCore
    public let ranking: SpectralRanking
    public let recoverNull: Bool
    public let analysis: FaithfulFrameAnalysis

    public init(
        ranking: SpectralRanking = .prominence,
        repairFallback: Bool = true,
        repairWaveform: Bool = true,
        refineWeak: Bool = true,
        recoverNull: Bool = true,
        analysis: FaithfulFrameAnalysis
    ) {
        self.ranking = ranking
        self.recoverNull = recoverNull
        self.analysis = analysis
        self.coreDetector = PitchDetectorCore(
            ranking: ranking,
            repairFallback: repairFallback,
            repairWaveform: repairWaveform,
            refineWeak: refineWeak,
            analysis: analysis
        )
    }

    /// Resets all internal state for a fresh stream.
    public func reset() {
        frames = 0
        stableAnchor = nil
        pairedAnchor = nil
        evidence.removeAll()
        coreDetector.reset()
    }

    /// Detects pitch with null recovery.
    public func detect(
        input: [Float],
        sampleRate: Double,
        sampleTime: Double? = nil
    ) -> FaithfulPitchCandidate? {
        let time = sampleTime ?? (Double(frames) * Double(FaithfulStreamingDetector.hopSize) / sampleRate * 1000.0)
        frames += 1

        var result = coreDetector.detect(input: input, sampleRate: sampleRate, sampleTime: time)
        guard recoverNull, ranking == .prominence else { return result }

        if let sa = stableAnchor, time - sa.time > 300.0 {
            stableAnchor = nil
            evidence.removeAll()
        }
        evidence.removeAll(where: { time - $0.time > 200.0 })

        var peaks: [FaithfulSpectralKernels.SpectralPeak]? = nil
        var cachedRms: Double? = nil
        func observedRms() -> Double {
            if let r = cachedRms { return r }
            guard !input.isEmpty else { return 0.0 }
            var mean = 0.0
            for value in input { mean += Double(value) }
            mean /= Double(input.count)
            var energy = 0.0
            for value in input {
                let diff = Double(value) - mean
                energy += diff * diff
            }
            let r = sqrt(energy / Double(input.count))
            cachedRms = r
            return r
        }

        if let res = result {
            if (res.confidence >= 0.95 && res.oddOnly == nil) || (stableAnchor != nil && agreesPitch(res.frequency, stableAnchor!.frequency, cents: 50.0)) {
                let entry = (frequency: res.frequency, time: time)
                stableAnchor = entry
                evidence.append(entry)
            }
        } else if let sa = stableAnchor,
                  evidence.count >= 3,
                  evidence.last!.time - evidence.first!.time >= 64.0,
                  agreesPitch(
                    evidence.map(\.frequency).reduce(-Double.infinity, max),
                    evidence.map(\.frequency).reduce(Double.infinity, min),
                    cents: 5.0
                  ),
                  observedRms() >= 0.000015 {
            peaks = analysis.peaks(input: input, rate: sampleRate)
            if let peak = peaks?.first,
               FaithfulStatelessDetector.validFrequency(peak.frequency, profile: analysis.profile),
               peak.prominence >= 500.0,
               agreesPitch(peak.frequency, sa.frequency, cents: 5.0),
               FaithfulStatelessDetector.filteredPeriodResidual(input: input, sampleRate: sampleRate, frequency: peak.frequency, analysis: analysis) <= 0.5 {
                let recovered = FaithfulPitchCandidate(frequency: peak.frequency, confidence: 0.8, rms: observedRms())
                result = recovered
                let entry = (frequency: recovered.frequency, time: time)
                stableAnchor = entry
                evidence.append(entry)
            }
        }

        if let pa = pairedAnchor, time - pa.time > 200.0 {
            pairedAnchor = nil
        }

        if let res = result {
            if (res.confidence >= 0.95 && res.oddOnly == nil) || (pairedAnchor != nil && agreesPitch(res.frequency, pairedAnchor!.frequency, cents: 50.0)) {
                pairedAnchor = (frequency: res.frequency, time: time)
            }
            return result
        }

        guard let pa = pairedAnchor else { return nil }
        if peaks == nil {
            peaks = analysis.peaks(input: input, rate: sampleRate)
        }
        let currentPeaks = peaks ?? []
        guard let fundamental = currentPeaks.first(where: { p in
            FaithfulStatelessDetector.validFrequency(p.frequency, profile: analysis.profile) && p.prominence >= 4.5 && agreesPitch(p.frequency, pa.frequency, cents: 30.0)
        }) else { return nil }

        guard let second = currentPeaks.first(where: { p in
            p.prominence >= 8.0 && agreesPitch(p.frequency / 2.0, fundamental.frequency, cents: 40.0)
        }) else { return nil }

        if second.power < fundamental.power * 0.2 || second.power > fundamental.power * 2.0 {
            return nil
        }

        let hasConflicting = currentPeaks.contains { p in
            p.frequency >= analysis.profile.minFrequency && p.frequency < fundamental.frequency * 0.75 && p.prominence >= 6.0 && p.power >= fundamental.power * 0.1
        }
        if hasConflicting {
            return nil
        }

        let frequency = (fundamental.frequency * fundamental.power + (second.frequency / 2.0) * second.power) / (fundamental.power + second.power)
        if !FaithfulStatelessDetector.validFrequency(frequency, profile: analysis.profile) ||
            FaithfulStatelessDetector.filteredPeriodResidual(input: input, sampleRate: sampleRate, frequency: frequency, analysis: analysis) > 0.7 ||
            observedRms() < 0.000015 {
            return nil
        }

        pairedAnchor = (frequency: frequency, time: time)
        return FaithfulPitchCandidate(frequency: frequency, confidence: 0.8, rms: observedRms())
    }

    public func callAsFunction(
        input: [Float],
        sampleRate: Double,
        sampleTime: Double? = nil
    ) -> FaithfulPitchCandidate? {
        detect(input: input, sampleRate: sampleRate, sampleTime: sampleTime)
    }
}

// MARK: - Layer 3: CanonicalPitchDetector

/// Third layer of the faithful streaming pitch detector.
/// Canonicalizes weak spectral period candidates using measured foreground peak corroboration.
/// Matches `createCanonicalPitchDetector` in reference-source/pitch.ts lines 296-333.
public final class CanonicalPitchDetector: @unchecked Sendable {
    public private(set) var frames: Int = 0
    public private(set) var anchor: (frequency: Double, time: Double)?

    public let recoveredDetector: RecoveredPitchDetector
    public let ranking: SpectralRanking
    public let repairSpectralOctave: Bool
    public let repairThird: Bool
    public let analysis: FaithfulFrameAnalysis

    public init(
        ranking: SpectralRanking = .prominence,
        repairFallback: Bool = true,
        repairWaveform: Bool = true,
        refineWeak: Bool = true,
        recoverNull: Bool = true,
        repairSpectralOctave: Bool = true,
        repairThird: Bool = true,
        analysis: FaithfulFrameAnalysis
    ) {
        self.ranking = ranking
        self.repairSpectralOctave = repairSpectralOctave
        self.repairThird = repairThird
        self.analysis = analysis
        self.recoveredDetector = RecoveredPitchDetector(
            ranking: ranking,
            repairFallback: repairFallback,
            repairWaveform: repairWaveform,
            refineWeak: refineWeak,
            recoverNull: recoverNull,
            analysis: analysis
        )
    }

    /// Resets all internal state for a fresh stream.
    public func reset() {
        frames = 0
        anchor = nil
        recoveredDetector.reset()
    }

    /// Detects pitch with canonical spectral octave repair.
    public func detect(
        input: [Float],
        sampleRate: Double,
        sampleTime: Double? = nil
    ) -> FaithfulPitchCandidate? {
        let time = sampleTime ?? (Double(frames) * Double(FaithfulStreamingDetector.hopSize) / sampleRate * 1000.0)
        frames += 1

        let raw = recoveredDetector.detect(input: input, sampleRate: sampleRate, sampleTime: time)
        guard repairSpectralOctave, ranking == .prominence else { return raw }

        if let a = anchor, time - a.time > 1000.0 {
            anchor = nil
        }

        var result = raw
        let multiples = repairThird ? [2, 3] : [2]
        let multiple: Int?
        if let raw = raw, let a = anchor {
            multiple = multiples.first(where: { agreesPitch(raw.frequency * Double($0), a.frequency, cents: 20.0) })
        } else {
            multiple = nil
        }

        if let raw = raw, raw.oddOnly != nil, let mult = multiple, anchor != nil {
            let peaks = analysis.peaks(input: input, rate: sampleRate)
            let lowerVisible = peaks.contains { p in
                p.prominence >= 15.0 && abs(p.frequency - raw.frequency) <= max(1.5, raw.frequency * 0.015)
            }
            let frequency = raw.frequency * Double(mult)
            let candidate = peaks.first { p in
                p.prominence >= 50.0 && abs(p.frequency - frequency) <= max(1.5, p.frequency * 0.015)
            }
            var voicedMaximum = 0.0
            for p in peaks {
                if p.frequency <= analysis.profile.maxFrequency && p.prominence >= 50.0 {
                    if p.power > voicedMaximum { voicedMaximum = p.power }
                }
            }

            if !lowerVisible && FaithfulStatelessDetector.validFrequency(frequency, profile: analysis.profile),
               let cand = candidate, cand.power >= voicedMaximum {
                struct MatchedPeak {
                    let peak: FaithfulSpectralKernels.SpectralPeak
                    let h: Int
                }
                var matched: [MatchedPeak] = []
                for p in peaks {
                    let h = Int(FaithfulSpectralKernels.jsRound(p.frequency / raw.frequency))
                    if h >= 1 && h <= 12 && abs(p.frequency / Double(h) - raw.frequency) <= max(1.5, raw.frequency * 0.008) {
                        matched.append(MatchedPeak(peak: p, h: h))
                    }
                }

                let unexplained = matched.contains { item in
                    item.h % mult != 0 && (
                        item.peak.power >= cand.power * 0.1 ||
                        (item.peak.prominence >= 15.0 && item.peak.power >= cand.power * 0.01 && matched.allSatisfy { ref in
                            ref.h >= item.h || ref.peak.power < item.peak.power || ref.peak.prominence < 15.0 ||
                            (item.peak.frequency / Double(item.h)) >= (ref.peak.frequency / Double(ref.h)) * pow(2.0, -5.0 / 1200.0)
                        })
                    )
                }

                if !unexplained {
                    var modified = raw
                    modified.frequency = (mult == 3 ? cand.frequency : frequency)
                    result = modified
                }
            }
        }

        if let res = result {
            if (res.confidence >= 0.95 && res.oddOnly == nil) || (anchor != nil && agreesPitch(res.frequency, anchor!.frequency, cents: 50.0)) {
                anchor = (frequency: res.frequency, time: time)
            }
        }

        return result
    }

    public func callAsFunction(
        input: [Float],
        sampleRate: Double,
        sampleTime: Double? = nil
    ) -> FaithfulPitchCandidate? {
        detect(input: input, sampleRate: sampleRate, sampleTime: sampleTime)
    }
}

// MARK: - Layer 4: FaithfulStreamingDetector (createPitchDetector)

/// Complete 4-layer faithful streaming pitch detector.
/// Owns the per-stream `FaithfulFrameAnalysis` scratch cache, applies third-harmonic waveform repair,
/// enforces stale oddOnly vetoes, tracks persistent foreground agreement, and attaches the
/// `foregroundAgrees` provenance flag.
/// Matches `createPitchDetector` in reference-source/pitch.ts lines 338-406.
public final class FaithfulStreamingDetector: @unchecked Sendable {
    public static let frameSize: Int = 4096
    public static let hopSize: Int = 1024
    public static let foregroundIdentityMs: Double = 1000.0

    public private(set) var frames: Int = 0
    public private(set) var accepted: Int = 0
    public private(set) var anchor: (frequency: Double, time: Double)?
    public private(set) var evidence: (frequency: Double, first: Double, last: Double)?

    public let ranking: SpectralRanking
    public let repairFallback: Bool
    public let repairWaveform: Bool
    public let refineWeak: Bool
    public let recoverNull: Bool
    public let repairSpectralOctave: Bool
    public let refineForeground: Bool

    public let analysis: FaithfulFrameAnalysis
    public let canonicalDetector: CanonicalPitchDetector

    public init(
        ranking: SpectralRanking = .prominence,
        repairFallback: Bool = true,
        repairWaveform: Bool? = nil,
        refineWeak: Bool? = nil,
        recoverNull: Bool? = nil,
        repairSpectralOctave: Bool? = nil,
        refineForeground: Bool? = nil,
        analysis: FaithfulFrameAnalysis? = nil,
        profile: FaithfulEngineProfile = .strictUkulele
    ) {
        let frameAnalysis = analysis ?? FaithfulFrameAnalysis(profile: profile)
        let repairWaveformVal = repairWaveform ?? repairFallback
        let refineWeakVal = refineWeak ?? repairWaveformVal
        let recoverNullVal = recoverNull ?? refineWeakVal
        let repairSpectralOctaveVal = repairSpectralOctave ?? recoverNullVal
        let refineForegroundVal = refineForeground ?? repairSpectralOctaveVal

        self.ranking = ranking
        self.repairFallback = repairFallback
        self.repairWaveform = repairWaveformVal
        self.refineWeak = refineWeakVal
        self.recoverNull = recoverNullVal
        self.repairSpectralOctave = repairSpectralOctaveVal
        self.refineForeground = refineForegroundVal
        self.analysis = frameAnalysis

        self.canonicalDetector = CanonicalPitchDetector(
            ranking: ranking,
            repairFallback: repairFallback,
            repairWaveform: repairWaveformVal,
            refineWeak: refineWeakVal,
            recoverNull: recoverNullVal,
            repairSpectralOctave: repairSpectralOctaveVal,
            repairThird: refineForegroundVal,
            analysis: frameAnalysis
        )
    }

    /// Resets all internal detector state across all layers for a fresh stream.
    public func reset() {
        frames = 0
        accepted = 0
        anchor = nil
        evidence = nil
        canonicalDetector.reset()
    }

    /// Detects pitch for an incoming capture-rate audio window.
    /// Resets `FaithfulFrameAnalysis` at the start of each frame.
    public func detect(
        input: [Float],
        sampleRate: Double,
        sampleTime: Double? = nil
    ) -> FaithfulPitchCandidate? {
        let time = sampleTime ?? (Double(frames) * Double(Self.hopSize) / sampleRate * 1000.0)
        frames += 1

        // Explicitly invalidate and prepare scratch cache for this incoming frame.
        analysis.begin(input: input, rate: sampleRate)

        var raw = canonicalDetector.detect(input: input, sampleRate: sampleRate, sampleTime: time)
        guard refineForeground, ranking == .prominence else { return raw }

        if let a = anchor, time - a.time > Self.foregroundIdentityMs {
            anchor = nil
        }

        var peaks: [FaithfulSpectralKernels.SpectralPeak]? = nil

        // Third-period waveform repair.
        if let r = raw, r.oddOnly == nil, r.confidence >= 0.75 && r.confidence < 0.95,
           let a = anchor, time - a.time <= 64.0, agreesPitch(r.frequency * 3.0, a.frequency, cents: 20.0) {
            peaks = analysis.peaks(input: input, rate: sampleRate)
            if let peak = peaks?.first, FaithfulStatelessDetector.validFrequency(peak.frequency, profile: analysis.profile),
               peak.prominence >= 50.0, agreesPitch(peak.frequency, r.frequency * 3.0, cents: 50.0) {
                let lower = peak.frequency / 3.0
                let lowerVisible = peaks?.contains { p in
                    p.prominence >= 15.0 && abs(p.frequency - lower) <= max(1.5, lower * 0.015)
                } ?? false
                let unexplained = peaks?.contains { p in
                    let h = Int(FaithfulSpectralKernels.jsRound(p.frequency / lower))
                    return h >= 1 && h <= 12 && (h % 3 != 0) &&
                        abs(p.frequency / Double(h) - lower) <= max(1.5, lower * 0.015) &&
                        p.power >= peak.power * 0.1
                } ?? false

                if !lowerVisible && !unexplained &&
                    FaithfulStatelessDetector.filteredPeriodResidual(input: input, sampleRate: sampleRate, frequency: peak.frequency, analysis: analysis) <= 0.35 {
                    let measured = r.frequency * 3.0
                    var modified = r
                    modified.frequency = agreesPitch(peak.frequency, measured, cents: 5.0) ? measured : peak.frequency
                    raw = modified
                }
            }
        }

        // Stale oddOnly veto: after 300 ms without anchor agreement and poor residual, veto to nil.
        if let r = raw, r.oddOnly != nil, let a = anchor,
           time - a.time > 300.0, !agreesPitch(r.frequency, a.frequency, cents: 50.0),
           FaithfulStatelessDetector.filteredPeriodResidual(input: input, sampleRate: sampleRate, frequency: r.frequency, analysis: analysis) > 0.7 {
            raw = nil
        }

        guard var validRaw = raw else {
            evidence = nil
            return nil
        }

        guard validRaw.confidence >= 0.75 else {
            evidence = nil
            return validRaw
        }

        anchor = (frequency: validRaw.frequency, time: time)
        accepted += 1

        // Persistent foreground agreement.
        if accepted > 5 && validRaw.confidence < 0.98 && validRaw.oddOnly == nil {
            if peaks == nil { peaks = analysis.peaks(input: input, rate: sampleRate) }
            let currentPeaks = peaks ?? []
            let peak = currentPeaks.first { p in
                FaithfulStatelessDetector.validFrequency(p.frequency, profile: analysis.profile) && p.prominence >= 1000.0 && agreesPitch(p.frequency, validRaw.frequency, cents: 15.0)
            }
            let conflicting = peak != nil && currentPeaks.contains { p in
                let h = Int(FaithfulSpectralKernels.jsRound(p.frequency / peak!.frequency))
                guard h > 0 else { return false }
                return p.frequency >= peak!.frequency * 0.75 && h <= 8 && p.power >= peak!.power * 0.1 &&
                    !agreesPitch(p.frequency, peak!.frequency * Double(h), cents: 5.0)
            }

            if peak == nil || conflicting || FaithfulStatelessDetector.filteredPeriodResidual(input: input, sampleRate: sampleRate, frequency: peak!.frequency, analysis: analysis) > 0.5 {
                evidence = nil
            } else {
                if evidence == nil || time - evidence!.last > 32.0 || !agreesPitch(peak!.frequency, evidence!.frequency, cents: 5.0) {
                    evidence = (frequency: peak!.frequency, first: time, last: time)
                } else {
                    evidence = (frequency: peak!.frequency, first: evidence!.first, last: time)
                }
                if time - evidence!.first >= 64.0 {
                    validRaw.frequency = peak!.frequency
                }
            }
        } else {
            evidence = nil
        }

        // Corroboration is provenance, not an inflated confidence score.
        if validRaw.confidence >= 0.95 && validRaw.confidence < 0.98 && validRaw.oddOnly == nil {
            if peaks == nil { peaks = analysis.peaks(input: input, rate: sampleRate) }
            if let peak = peaks?.first,
               peak.prominence >= 50.0,
               agreesPitch(peak.frequency, validRaw.frequency, cents: 5.0),
               FaithfulStatelessDetector.filteredPeriodResidual(input: input, sampleRate: sampleRate, frequency: validRaw.frequency, analysis: analysis) <= 0.5 {
                validRaw.foregroundAgrees = true
                return validRaw
            }
        }

        return validRaw
    }

    public func callAsFunction(
        input: [Float],
        sampleRate: Double,
        sampleTime: Double? = nil
    ) -> FaithfulPitchCandidate? {
        detect(input: input, sampleRate: sampleRate, sampleTime: sampleTime)
    }
}

// MARK: - Factory Functions Matching TypeScript API

/// Factory function creating a `PitchDetectorCore`.
public func createPitchDetectorCore(
    ranking: SpectralRanking = .prominence,
    repairFallback: Bool = true,
    repairWaveform: Bool = true,
    refineWeak: Bool = true,
    analysis: FaithfulFrameAnalysis
) -> PitchDetectorCore {
    PitchDetectorCore(
        ranking: ranking,
        repairFallback: repairFallback,
        repairWaveform: repairWaveform,
        refineWeak: refineWeak,
        analysis: analysis
    )
}

/// Factory function creating a `RecoveredPitchDetector`.
public func createRecoveredPitchDetector(
    ranking: SpectralRanking = .prominence,
    repairFallback: Bool = true,
    repairWaveform: Bool = true,
    refineWeak: Bool = true,
    recoverNull: Bool = true,
    analysis: FaithfulFrameAnalysis
) -> RecoveredPitchDetector {
    RecoveredPitchDetector(
        ranking: ranking,
        repairFallback: repairFallback,
        repairWaveform: repairWaveform,
        refineWeak: refineWeak,
        recoverNull: recoverNull,
        analysis: analysis
    )
}

/// Factory function creating a `CanonicalPitchDetector`.
public func createCanonicalPitchDetector(
    ranking: SpectralRanking = .prominence,
    repairFallback: Bool = true,
    repairWaveform: Bool = true,
    refineWeak: Bool = true,
    recoverNull: Bool = true,
    repairSpectralOctave: Bool = true,
    repairThird: Bool = true,
    analysis: FaithfulFrameAnalysis
) -> CanonicalPitchDetector {
    CanonicalPitchDetector(
        ranking: ranking,
        repairFallback: repairFallback,
        repairWaveform: repairWaveform,
        refineWeak: refineWeak,
        recoverNull: recoverNull,
        repairSpectralOctave: repairSpectralOctave,
        repairThird: repairThird,
        analysis: analysis
    )
}

/// Factory function creating a full `FaithfulStreamingDetector`.
/// Matches `createPitchDetector` in reference-source/pitch.ts lines 338-340.
public func createPitchDetector(
    ranking: SpectralRanking = .prominence,
    repairFallback: Bool = true,
    repairWaveform: Bool? = nil,
    refineWeak: Bool? = nil,
    recoverNull: Bool? = nil,
    repairSpectralOctave: Bool? = nil,
    refineForeground: Bool? = nil,
    analysis: FaithfulFrameAnalysis? = nil,
    profile: FaithfulEngineProfile = .strictUkulele
) -> FaithfulStreamingDetector {
    FaithfulStreamingDetector(
        ranking: ranking,
        repairFallback: repairFallback,
        repairWaveform: repairWaveform,
        refineWeak: refineWeak,
        recoverNull: recoverNull,
        repairSpectralOctave: repairSpectralOctave,
        refineForeground: refineForeground,
        analysis: analysis,
        profile: profile
    )
}

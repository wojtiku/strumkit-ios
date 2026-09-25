import Foundation
import Accelerate

/// Complete native Swift implementation of chorder's pitch analysis pipeline (pitch.ts).
/// Features:
/// - Polyphase sinc resampling to 16,000 Hz.
/// - Single-pass clipping and RMS estimation.
/// - YIN difference function & CMNDF with local trough detection.
/// - Sub-sample parabolic interpolation with curvature guard.
/// - Multiplier candidate arbitration (2x, 3x, 4x) using Hann power projection to eliminate octave doubling.
/// - Prior frequency continuity tracking and ambiguity detection.
public final class PitchDetector: @unchecked Sendable {
    public static let minAnalysisRMS: Double = 0.00006
    public static let curvatureEpsilon: Double = 1e-15
    public static let refinementRadius: Int = 2
    public static let candidateSearchRadius: Int = 2
    public static let fallbackResidualLimit: Double = 0.35
    public static let candidateMultipliers: [Int] = [2, 3, 4]

    public static let priorSubharmonicMaxDistanceCents: Double = 35.0
    public static let priorSubharmonicMinEnergyRatio: Double = 0.05
    public static let unprioritizedSubharmonicMinEnergyRatio: Double = 0.30
    public static let fundamentalMinEnergyRatio: Double = 0.004
    public static let highNoteAmbiguityMinEnergyRatio: Double = 0.002
    public static let standardAmbiguityMinEnergyRatio: Double = 0.004
    public static let harmonicSupportMinRatio: Double = 0.5

    public static let clippingSampleLevel: Float = 0.98
    public static let clippingFraction: Double = 0.01

    private let resampler = Resampler()
    public let sampleRate: Double
    public let bufferSize: Int
    public let minFrequency: Double
    public let maxFrequency: Double

    public init(
        sampleRate: Double = 44100.0,
        bufferSize: Int = 2048,
        minFrequency: Double = TunerConstants.detectorMinHz,
        maxFrequency: Double = TunerConstants.detectorMaxHz
    ) {
        self.sampleRate = sampleRate
        self.bufferSize = bufferSize
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
    }

    /// Full window analysis matching analyzeWindow from chorder/src/audio/tuner/pitch.ts
    public func detectPitch(
        in buffer: [Float],
        noiseGateRMS: Float = 0.0001,
        yinThreshold: Float = 0.15,
        referenceA4: Double = TunerConstants.defaultA4Hz,
        priorFrequency: Double? = nil,
        priorAt: TimeInterval? = nil,
        now: TimeInterval = 0
    ) -> PitchResult {
        guard !buffer.isEmpty else { return .idle }

        // 1. Clipping detection
        var clippedCount = 0
        for s in buffer {
            if abs(s) >= Self.clippingSampleLevel {
                clippedCount += 1
            }
        }
        let isClipping = Double(clippedCount) / Double(buffer.count) >= Self.clippingFraction

        // 2. Resample trailing window to 16,000 Hz if needed
        let samples: [Float]
        let analysisRate: Double
        if let resampled = resampler.resampleWindow(source: buffer, inputRate: sampleRate) {
            samples = resampled
            analysisRate = Resampler.analysisRate
        } else {
            samples = buffer
            analysisRate = sampleRate
        }

        let count = samples.count
        guard count >= 512 else { return .idle }

        // 3. DC Removal & RMS calculation
        var mean: Float = 0.0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(count))
        var zeroCentered = [Float](repeating: 0.0, count: count)
        var negMean = -mean
        vDSP_vsadd(samples, 1, &negMean, &zeroCentered, 1, vDSP_Length(count))

        var rms: Float = 0.0
        vDSP_rmsqv(zeroCentered, 1, &rms, vDSP_Length(count))
        let rmsDouble = Double(rms)

        if rmsDouble < Self.minAnalysisRMS || isClipping || rms < noiseGateRMS {
            return PitchResult(
                frequency: 0,
                closestNote: MusicalNote(midiNoteNumber: 69, referenceA4: referenceA4),
                centsDeviation: 0,
                confidence: 0,
                amplitudeRMS: rmsDouble,
                isSignalPresent: false,
                isClipped: isClipping
            )
        }

        // 4. Difference Function & CMNDF
        let minLag = max(2, Int(floor(analysisRate / maxFrequency)))
        let maxLag = min(count / 2, Int(ceil(analysisRate / minFrequency)))
        guard maxLag > minLag else { return .idle }

        let span = count - maxLag
        var difference = [Double](repeating: 0.0, count: maxLag + 1)
        var cmnd = [Double](repeating: 1.0, count: maxLag + 1)

        var diffSum: Double = 0.0
        for lag in 1...maxLag {
            var value: Double = 0.0
            for i in 0..<span {
                let diff = Double(zeroCentered[i] - zeroCentered[i + lag])
                value += diff * diff
            }
            difference[lag] = value
            diffSum += value
            cmnd[lag] = diffSum > 0 ? (value * Double(lag)) / diffSum : 1.0
        }

        // 5. Trough Selection
        var chosen = -1
        let threshold = Double(yinThreshold)
        for lag in minLag...maxLag {
            if cmnd[lag] <= threshold {
                var l = lag
                while l < maxLag && cmnd[l + 1] < cmnd[l] {
                    l += 1
                }
                chosen = l
                break
            }
        }

        // Global minimum fallback
        if chosen < 0 {
            var globalMinLag = -1
            var minResidual = Double.greatestFiniteMagnitude
            for lag in minLag...maxLag {
                if cmnd[lag] < minResidual {
                    minResidual = cmnd[lag]
                    globalMinLag = lag
                }
            }
            if globalMinLag >= minLag && minResidual <= Self.fallbackResidualLimit {
                chosen = globalMinLag
            }
        }

        guard chosen >= minLag else {
            return PitchResult(
                frequency: 0,
                closestNote: MusicalNote(midiNoteNumber: 69, referenceA4: referenceA4),
                centsDeviation: 0,
                confidence: 0,
                amplitudeRMS: rmsDouble,
                isSignalPresent: true
            )
        }

        // 6. Parabolic Refinement Function
        func refine(lag: Int) -> (lag: Int, frequency: Double) {
            var best = lag
            let low = max(minLag, lag - Self.refinementRadius)
            let high = min(maxLag, lag + Self.refinementRadius)
            for cand in low...high {
                if difference[cand] < difference[best] {
                    best = cand
                }
            }
            var offset = 0.0
            if best > 1 && best < maxLag {
                let left = difference[best - 1]
                let middle = difference[best]
                let right = difference[best + 1]
                let denominator = left - 2.0 * middle + right
                if denominator > Self.curvatureEpsilon {
                    offset = max(-0.5, min(0.5, 0.5 * (left - right) / denominator))
                }
            }
            return (best, analysisRate / (Double(best) + offset))
        }

        let initial = refine(lag: chosen)
        var refined = initial
        var selectedMultiplier = 1
        var candidateEvidence = 0

        // 7. Multiplier Candidate Arbitration (2x, 3x, 4x subharmonic search)
        //
        // Shares the tracker's continuity grace window rather than repeating the
        // value: a stale subharmonic prior is the same failure in both places, and
        // two literals would drift apart the first time one was tuned.
        let priorWindow = PitchTracker.priorGraceDuration
        let hasPrior: Bool
        if let priorAt, let priorFrequency {
            hasPrior = (now >= priorAt) && (now - priorAt <= priorWindow) && priorFrequency.isFinite
        } else {
            hasPrior = false
        }

        for multiplier in Self.candidateMultipliers {
            let candidateFreq = initial.frequency / Double(multiplier)
            guard candidateFreq >= minFrequency && candidateFreq <= maxFrequency else { continue }
            let candidateLag = Int(round(analysisRate / candidateFreq))
            guard candidateLag <= maxLag else { continue }

            let bestCandLag = localMinimumNear(cmnd: cmnd, expected: candidateLag, minLag: minLag, maxLag: maxLag)
            guard bestCandLag >= 0 && cmnd[bestCandLag] <= Self.fallbackResidualLimit else { continue }

            let candidate = refine(lag: bestCandLag)
            let evidence = measureCandidateEvidence(samples: zeroCentered, candidateFrequency: candidate.frequency, selectedFrequency: initial.frequency, rate: analysisRate)
            let candidatePowerRatio = evidence.candidateEnergy / (rmsDouble * rmsDouble)

            let priorMatches: Bool
            if hasPrior, let priorFrequency {
                priorMatches = abs(1200.0 * log2(candidate.frequency / priorFrequency)) <= Self.priorSubharmonicMaxDistanceCents
            } else {
                priorMatches = false
            }

            if candidatePowerRatio >= Self.fundamentalMinEnergyRatio
                && cmnd[candidate.lag] < cmnd[initial.lag]
                && evidence.harmonicSupport >= evidence.selectedEnergy * Self.harmonicSupportMinRatio {
                candidateEvidence |= (1 << multiplier)
            }

            if shouldPreferSubharmonic(
                candidateResidual: cmnd[candidate.lag],
                selectedResidual: cmnd[initial.lag],
                evidence: evidence,
                power: rmsDouble * rmsDouble,
                priorMatches: priorMatches
            ) {
                refined = candidate
                selectedMultiplier = multiplier
            }
        }

        // 8. Ambiguity Checking
        var isAmbiguous = false
        for multiplier in Self.candidateMultipliers {
            if (candidateEvidence & (1 << multiplier)) != 0 && (selectedMultiplier % multiplier != 0) {
                isAmbiguous = true
            }
        }

        let periodicity = max(0.0, min(1.0, 1.0 - cmnd[refined.lag]))
        let frequency = refined.frequency
        guard frequency >= minFrequency && frequency <= maxFrequency else { return .idle }

        var ambiguousThresh = frequency > 300.0 ? Self.highNoteAmbiguityMinEnergyRatio : Self.standardAmbiguityMinEnergyRatio
        if hasPrior {
            ambiguousThresh *= 0.5
        }
        let fundamentalEnergy = HannProjection.normalizedPower(samples: zeroCentered, frequency: frequency, sampleRate: analysisRate)
        if (fundamentalEnergy / (rmsDouble * rmsDouble)) < ambiguousThresh {
            isAmbiguous = true
        }

        guard !isAmbiguous, let nearest = MusicalNote.closest(to: frequency, referenceA4: referenceA4) else {
            return PitchResult(
                frequency: 0,
                closestNote: MusicalNote(midiNoteNumber: 69, referenceA4: referenceA4),
                centsDeviation: 0,
                confidence: periodicity,
                amplitudeRMS: rmsDouble,
                isSignalPresent: true
            )
        }

        return PitchResult(
            frequency: frequency,
            closestNote: nearest.note,
            centsDeviation: nearest.cents,
            confidence: periodicity,
            amplitudeRMS: rmsDouble,
            isSignalPresent: true
        )
    }

    // MARK: - Private Candidate Evidence Helpers

    private func localMinimumNear(cmnd: [Double], expected: Int, minLag: Int, maxLag: Int) -> Int {
        var best = -1
        let low = max(minLag, expected - Self.candidateSearchRadius)
        let high = min(maxLag, expected + Self.candidateSearchRadius)
        guard high >= low else { return -1 }

        for lag in low...high {
            let belowLeft = (lag == minLag || cmnd[lag] <= cmnd[lag - 1])
            let belowRight = (lag == maxLag || cmnd[lag] <= cmnd[lag + 1])
            if belowLeft && belowRight && (best < 0 || cmnd[lag] < cmnd[best]) {
                best = lag
            }
        }
        return best
    }

    private struct CandidateEvidence {
        let selectedEnergy: Double
        let candidateEnergy: Double
        let harmonicSupport: Double
    }

    private func measureCandidateEvidence(
        samples: [Float],
        candidateFrequency: Double,
        selectedFrequency: Double,
        rate: Double
    ) -> CandidateEvidence {
        let selectedEnergy = HannProjection.normalizedPower(samples: samples, frequency: selectedFrequency, sampleRate: rate)
        let candidateEnergy = HannProjection.normalizedPower(samples: samples, frequency: candidateFrequency, sampleRate: rate)
        var harmonicSupport = 0.0

        for multiplier in Self.candidateMultipliers {
            let freq = candidateFrequency * Double(multiplier)
            if freq <= maxFrequency && freq < rate / 2.0 {
                harmonicSupport += HannProjection.normalizedPower(samples: samples, frequency: freq, sampleRate: rate)
            }
        }

        return CandidateEvidence(selectedEnergy: selectedEnergy, candidateEnergy: candidateEnergy, harmonicSupport: harmonicSupport)
    }

    private func shouldPreferSubharmonic(
        candidateResidual: Double,
        selectedResidual: Double,
        evidence: CandidateEvidence,
        power: Double,
        priorMatches: Bool
    ) -> Bool {
        if evidence.candidateEnergy / power < Self.fundamentalMinEnergyRatio {
            return false
        }
        if priorMatches {
            return evidence.candidateEnergy >= evidence.selectedEnergy * Self.priorSubharmonicMinEnergyRatio
        }
        return candidateResidual < selectedResidual
            && evidence.candidateEnergy >= evidence.selectedEnergy * Self.unprioritizedSubharmonicMinEnergyRatio
            && evidence.harmonicSupport >= evidence.selectedEnergy * Self.harmonicSupportMinRatio
    }
}

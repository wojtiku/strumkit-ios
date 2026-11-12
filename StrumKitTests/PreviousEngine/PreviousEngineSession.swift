import Foundation
import QuartzCore
@testable import StrumKit

/// What the previous engine reported for one window.
struct PreviousEngineSnapshot {
    let reading: TunerReading?
    let pitchResult: PitchResult
    let feedbackState: PreviousSignalFeedbackState
    let guidedProgress: [Bool]
    let guidedTargetIndex: Int
    let diagnostics: TunerDiagnostics
    let generation: UInt64
    let sequence: UInt64
}

/// The previous engine, assembled: YIN detector, spectral recovery, pitch tracker.
///
/// A comparison oracle. The app no longer runs any of this — it runs the Reading
/// engine — but the suites that measured this engine on recorded and synthetic audio are
/// kept, and this is the one place they get it assembled. It used to be a branch inside
/// the app's analysis session, selected by injecting a tracker.
final class PreviousEngineSession {
    private let tracker: PitchTracker
    private var detector: PitchDetector?
    private let spectralScorer = SpectralPitchScorer()
    private var previousFrameRms: Double = 0.0
    private let fundamentalEnergyScale: Double

    private var config: TunerConfig
    private var targets: [StringTarget]

    private static let onsetRmsRatio: Double = 2.5
    private static let onsetMinRMS: Double = 0.005
    private static let spectralRecoveryMinScore: Double = 0.035
    private static let spectralRecoveryMinRMS: Double = 0.0003
    private static let spectralRecoverySeparationRatio: Double = 1.25
    private static let spectralRecoveryMinHarmonics: Int = 2
    private static let spectralSupportFraction: Double = 0.15
    private static let spectralSearchRadiusCents: Double = 70.0

    var isSpectralRecoveryEnabled: Bool = true

    /// Constant: nothing here invalidates in flight. Kept so a frame built for the
    /// app's session can be built the same way for this one.
    let generation: UInt64 = 1

    var continuityPrior: (frequency: Double, at: TimeInterval)? { tracker.continuityPrior }

    init(
        config: TunerConfig = TunerConfig(),
        targets: [StringTarget] = [],
        tracker: PitchTracker,
        fundamentalEnergyScale: Double = PitchDetector.defaultFundamentalEnergyScale
    ) {
        self.config = config
        self.targets = targets
        self.tracker = tracker
        self.fundamentalEnergyScale = fundamentalEnergyScale
    }

    func processFrameSync(_ frame: AnalysisFrame) -> PreviousEngineSnapshot? {
        guard frame.generation == generation else { return nil }

        let activeDetector: PitchDetector
        if let existing = detector, existing.sampleRate == frame.sampleRate, existing.bufferSize == frame.samples.count {
            activeDetector = existing
        } else {
            let newlyCreated = PitchDetector(
                sampleRate: frame.sampleRate, bufferSize: frame.samples.count,
                fundamentalEnergyScale: fundamentalEnergyScale)
            detector = newlyCreated
            activeDetector = newlyCreated
        }

        let prior = tracker.continuityPrior
        let isSustaining = (prior != nil)
        let noiseGate = tracker.recommendedNoiseGate(isSustaining: isSustaining)
        let yinThreshold = tracker.recommendedYinThreshold(isSustaining: isSustaining)

        let livePrior: (frequency: Double, at: TimeInterval)?
        if let prior,
           frame.captureEndSeconds >= prior.at,
           (frame.captureEndSeconds - prior.at) <= PitchTracker.priorGraceDuration {
            livePrior = prior
        } else {
            livePrior = nil
        }

        let dspStart = CACurrentMediaTime()

        var pitchResult = activeDetector.detectPitch(
            in: frame.samples,
            noiseGateRMS: noiseGate,
            yinThreshold: yinThreshold,
            referenceA4: config.a4,
            livePriorFrequency: livePrior?.frequency
        )

        let currentRms = pitchResult.amplitudeRMS
        let isOnset = (previousFrameRms > 0)
            && (currentRms >= previousFrameRms * Self.onsetRmsRatio)
            && (currentRms > Self.onsetMinRMS)
        previousFrameRms = currentRms

        if isSpectralRecoveryEnabled, let prior = livePrior, !isOnset {
            let yinFailed = !pitchResult.isSignalPresent || pitchResult.frequency <= 0
            let yinJumped: Bool
            if pitchResult.isSignalPresent && pitchResult.frequency > 0 {
                let jumpCents = abs(PitchMath.centsBetween(measured: pitchResult.frequency, reference: prior.frequency))
                yinJumped = (jumpCents > Self.spectralSearchRadiusCents)
            } else {
                yinJumped = false
            }

            if (yinFailed || yinJumped) && currentRms >= Self.spectralRecoveryMinRMS {
                if let analysis = spectralScorer.analyzeAudio(samples: frame.samples, sampleRate: frame.sampleRate) {
                    applySpectralRecovery(analysis: analysis, prior: prior, currentRms: currentRms, to: &pitchResult)
                }
            }
        }

        let reading = tracker.process(
            pitchResult: pitchResult,
            at: frame.captureEndSeconds,
            config: config,
            targets: targets
        )

        let dspMs = (CACurrentMediaTime() - dspStart) * 1000.0
        let diagnostics = TunerDiagnostics(
            sampleRate: frame.sampleRate,
            analysisMs: dspMs,
            dspMs: dspMs,
            queueDelayMs: 0.0,
            resultAgeMs: 0.0,
            overloads: 0,
            callbackFrameCount: frame.callbackFrameCount,
            dropped: 0,
            level: pitchResult.amplitudeRMS
        )

        return PreviousEngineSnapshot(
            reading: reading,
            pitchResult: pitchResult,
            feedbackState: tracker.feedbackState,
            guidedProgress: tracker.guidedProgress,
            guidedTargetIndex: tracker.guidedTargetIndex,
            diagnostics: diagnostics,
            generation: frame.generation,
            sequence: frame.sequence
        )
    }

    private func applySpectralRecovery(
        analysis: SpectralPitchScorer.WindowAnalysis,
        prior: (frequency: Double, at: TimeInterval),
        currentRms: Double,
        to pitchResult: inout PitchResult
    ) {
        let radius = Self.spectralSearchRadiusCents
        let candidates = analysis.candidates

        guard let index = candidates.firstIndex(where: { candidate in
            candidate.frequency > 0
                && abs(PitchMath.centsBetween(measured: candidate.frequency, reference: prior.frequency)) <= radius
        }) else { return }

        let candidate = candidates[index]
        guard candidate.score >= Self.spectralRecoveryMinScore else { return }

        guard index < analysis.evidence.count else { return }
        let evidence = analysis.evidence[index]
        let strongest = evidence.map { Double($0.peakMagnitude) }.max() ?? 0
        guard strongest > 0 else { return }
        let supporting = evidence.filter {
            $0.peakFrequency != nil && Double($0.peakMagnitude) >= strongest * Self.spectralSupportFraction
        }
        guard supporting.count >= Self.spectralRecoveryMinHarmonics else { return }

        if let competitor = candidates.first(where: {
            $0.frequency > 0
                && abs(PitchMath.centsBetween(measured: $0.frequency, reference: prior.frequency)) > radius
        }) {
            guard candidate.score >= competitor.score * Self.spectralRecoverySeparationRatio else { return }
        }

        guard let nearestMidi = PitchMath.nearestMidi(for: candidate.frequency, a4: config.a4) else { return }

        pitchResult = PitchResult(
            frequency: candidate.frequency,
            closestNote: MusicalNote(midiNoteNumber: nearestMidi.midi, referenceA4: config.a4),
            centsDeviation: nearestMidi.cents,
            confidence: min(0.70, candidate.score / 2.0),
            amplitudeRMS: currentRms,
            isSignalPresent: true,
            evidence: .sustained
        )
    }
}

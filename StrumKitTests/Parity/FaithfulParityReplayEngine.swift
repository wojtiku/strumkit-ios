// StrumKitTests/Parity/FaithfulParityReplayEngine.swift
import Foundation
import CryptoKit
@testable import StrumKit

/// Pure Swift replay engine chaining the full faithful algorithm pipeline:
/// CaptureFraming -> StreamingDetector -> TargetTracker -> Presentation -> TuningFeedback.
///
/// Bit-identically conforms to the test-tuner parity contract.
public final class FaithfulParityReplayEngine: ParityReplayEngine, @unchecked Sendable {
    public var onFrame: (@Sendable (Int, FaithfulTracker, FaithfulPresentation, TuningFeedback) -> Void)?

    public init(onFrame: (@Sendable (Int, FaithfulTracker, FaithfulPresentation, TuningFeedback) -> Void)? = nil) {
        self.onFrame = onFrame
    }

    /// Computes the SHA-256 hash of a Float buffer in little-endian binary format,
    /// matching `hashSamples` in Tools/parity-contract/runner.ts.
    public static func hashSamples(_ samples: [Float]) -> String {
        samples.withUnsafeBufferPointer { buffer in
            let rawBuffer = UnsafeRawBufferPointer(buffer)
            let digest = SHA256.hash(data: Data(rawBuffer))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    public func replay(
        samples: [Float],
        sampleRate: Double,
        config: ParityReplayConfig
    ) throws -> ParityTrace {
        let detector = createPitchDetector()
        let tracker = FaithfulTracker()
        tracker.tuning = config.tuning
        tracker.auto = config.auto
        let presentation = FaithfulPresentation()
        let feedback = TuningFeedback()

        var frames: [ParityFrame] = []
        var confirmedNotes: [String] = []

        let workletOffsetMs = (128.0 / sampleRate) * 1000.0

        let processFrame: ([Float], Int, Double, Int) -> Void = { frame, sampleIndex, timeMs, frameIndex in
            if let hook = self.onFrame {
                hook(frameIndex, tracker, presentation, feedback)
            } else if config.name == "vector-reset-events" && frameIndex == 35 {
                tracker.reset()
                presentation.reset()
                feedback.clearReading()
            }

            let workletTimeMs = timeMs - workletOffsetMs

            var energy: Double = 0.0
            var hasNonFinite = false
            for s in frame {
                if !s.isFinite {
                    hasNonFinite = true
                    break
                }
                let v = Double(s)
                energy += v * v
            }
            let frameRms: Double?
            if hasNonFinite {
                frameRms = nil
            } else if frame.isEmpty {
                frameRms = 0.0
            } else {
                frameRms = sqrt(energy / Double(frame.count))
            }

            let raw = detector.detect(input: frame, sampleRate: sampleRate, sampleTime: timeMs)
            let tracked = tracker.push(pitch: raw, time: timeMs)
            let confirmed = feedback.observe(tracked)
            if confirmed, let tracked = tracked {
                confirmedNotes.append(tracked.note)
            }
            let published = presentation.push(reading: tracked, time: timeMs)

            let pubAction: ParityPublicationAction
            let pubNote: String?
            let pubCents: Double?
            let pubFreq: Double?
            let pubInTune: Bool?

            switch published {
            case .skipped:
                pubAction = .skipped
                pubNote = nil
                pubCents = nil
                pubFreq = nil
                pubInTune = nil
            case .empty:
                pubAction = .empty
                pubNote = nil
                pubCents = nil
                pubFreq = nil
                pubInTune = nil
            case .published(let publishedReading, _):
                pubNote = publishedReading.note
                pubCents = publishedReading.cents
                pubFreq = publishedReading.frequency
                pubInTune = publishedReading.inTune
                if let tracked = tracked, tracked.cents == publishedReading.cents, tracked.note == publishedReading.note {
                    pubAction = .published
                } else {
                    pubAction = .held
                }
            }

            let currentTuning = TUNINGS[tracker.tuning] ?? TUNINGS["standard"]!
            let targetObj: ParityTarget?
            if let tracked = tracked, tracked.index >= 0 && tracked.index < currentTuning.count {
                targetObj = ParityTarget(
                    note: tracked.note,
                    frequency: currentTuning[tracked.index].frequency,
                    index: tracked.index
                )
            } else {
                targetObj = nil
            }

            let rawCents: Double?
            if let rawFreq = raw?.frequency, let targetObj = targetObj {
                rawCents = centsBetween(frequency: rawFreq, reference: targetObj.frequency)
            } else {
                rawCents = nil
            }

            let detectorOutput = ParityDetectorOutput(
                frequency: raw?.frequency,
                confidence: raw?.confidence,
                rms: raw?.rms ?? frameRms,
                foregroundAgrees: raw?.foregroundAgrees,
                oddOnly: raw?.oddOnly
            )

            let trackerOutput = ParityTrackerOutput(
                target: targetObj,
                rawCents: rawCents,
                smoothedCents: tracked?.cents,
                readingFrequency: tracked?.frequency,
                inTune: tracked?.inTune ?? false
            )

            let pubOutput = ParityPublicationOutput(
                action: pubAction,
                note: pubNote,
                cents: pubCents,
                frequency: pubFreq,
                inTune: pubInTune
            )

            let confirmOutput = ParityConfirmationOutput(
                event: confirmed,
                stringIndex: tracked?.index,
                note: tracked?.note
            )

            let parityFrame = ParityFrame(
                frameIndex: frameIndex,
                sampleIndex: sampleIndex,
                timeMs: timeMs,
                workletTimeMs: workletTimeMs,
                detector: detectorOutput,
                tracker: trackerOutput,
                publication: pubOutput,
                confirmation: confirmOutput
            )

            frames.append(parityFrame)
        }

        if let customFrames = config.customFrames {
            for (i, custom) in customFrames.enumerated() {
                let sampleIndex = Int(round((custom.timeMs / 1000.0) * sampleRate))
                processFrame(custom.frame, sampleIndex, custom.timeMs, i)
            }
        } else {
            let framer = FaithfulCaptureFraming(
                sampleRate: sampleRate,
                bufferCapacity: max(16384, samples.count + 4096),
                initialGeneration: 1
            )
            let captureWindows = framer.process(channel: samples)
            for window in captureWindows {
                processFrame(window.samples, window.sampleIndex, window.timeMs, window.frameIndex)
            }
        }

        return ParityTrace(
            name: config.name,
            category: config.category,
            sampleRate: sampleRate,
            sampleCount: samples.count,
            sampleSha256: Self.hashSamples(samples),
            frameCount: frames.count,
            clockConvention: "window-end",
            workletOffsetMs: workletOffsetMs,
            confirmedNotes: confirmedNotes,
            frames: frames
        )
    }
}

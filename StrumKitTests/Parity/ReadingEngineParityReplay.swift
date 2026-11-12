// StrumKitTests/Parity/ReadingEngineParityReplay.swift
import Foundation
import CryptoKit
@testable import StrumKit

/// Replays PCM through the app's `ReadingEngine` and writes down what it did, hop by
/// hop, in the parity contract's terms.
///
/// Nothing is assembled here. The framer, detector, tracker and display throttle are
/// the engine's, exactly as the app runs them; this type only feeds it audio and
/// translates each hop's trace. The one thing it adds is the reference's
/// `TuningFeedback`, which the contract records confirmation events from and the app
/// does not use.
public final class ReadingEngineParityReplay: ParityReplayEngine, @unchecked Sendable {
    public init() {}

    /// Computes SHA-256 hash of Float32 PCM sample data matching Node crypto format.
    public static func hashSamples(_ samples: [Float]) -> String {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The frame at which the `vector-reset-events` case changes the tuner's settings.
    private static let resetEventFrame = 35

    public func replay(
        samples: [Float],
        sampleRate: Double,
        config: ParityReplayConfig
    ) throws -> ParityTrace {
        let tuning = TUNINGS[config.tuning] ?? TUNINGS["standard"]!
        let configuration = ReadingEngine.Configuration(
            profile: .strictUkulele,
            targets: tuning.enumerated().map { index, target in
                StringTarget(note: target.note, midi: target.midi, frequency: target.frequency, number: tuning.count - index)
            },
            calibrationA4: 440.0,
            mode: config.auto ? .auto : .manual,
            selectedString: 0
        )
        let engine = ReadingEngine(configuration: configuration, sampleRate: sampleRate)
        let feedback = TuningFeedback()
        let resetsMidStream = config.name == "vector-reset-events"
        let workletOffsetMs = (128.0 / sampleRate) * 1000.0

        var frames: [ParityFrame] = []
        var confirmedNotes: [String] = []

        // A settings change, as the app makes one: the engine forgets the Reading and
        // keeps the stream.
        func resetIfDue(before frameIndex: Int) {
            guard resetsMidStream, frameIndex == Self.resetEventFrame else { return }
            engine.configure(configuration)
            feedback.clearReading()
        }

        func record(_ hop: ReadingEngine.Hop) {
            let trace = hop.trace
            let raw = trace.candidate
            let tracked = trace.tracked

            let confirmed = feedback.observe(tracked)
            if confirmed, let tracked { confirmedNotes.append(tracked.note) }

            let publication: ParityPublicationOutput
            switch trace.publication {
            case .skipped:
                publication = ParityPublicationOutput(action: .skipped, note: nil, cents: nil, frequency: nil, inTune: nil)
            case .empty:
                publication = ParityPublicationOutput(action: .empty, note: nil, cents: nil, frequency: nil, inTune: nil)
            case .published(let shown, _):
                let isThisFrames = tracked.map { $0.cents == shown.cents && $0.note == shown.note } ?? false
                publication = ParityPublicationOutput(
                    action: isThisFrames ? .published : .held,
                    note: shown.note, cents: shown.cents, frequency: shown.frequency, inTune: shown.inTune)
            }

            let target: ParityTarget?
            if let tracked, tuning.indices.contains(tracked.index) {
                target = ParityTarget(note: tracked.note, frequency: tuning[tracked.index].frequency, index: tracked.index)
            } else {
                target = nil
            }
            let rawCents: Double?
            if let rawFrequency = raw?.frequency, let target {
                rawCents = centsBetween(frequency: rawFrequency, reference: target.frequency)
            } else {
                rawCents = nil
            }

            frames.append(ParityFrame(
                frameIndex: trace.frameIndex,
                sampleIndex: trace.sampleIndex,
                timeMs: trace.streamTimeMs,
                workletTimeMs: trace.workletTimeMs,
                detector: ParityDetectorOutput(
                    frequency: raw?.frequency,
                    confidence: raw?.confidence,
                    rms: raw?.rms ?? (trace.windowRMS.isFinite ? trace.windowRMS : nil),
                    foregroundAgrees: raw?.foregroundAgrees,
                    oddOnly: raw?.oddOnly
                ),
                tracker: ParityTrackerOutput(
                    target: target,
                    rawCents: rawCents,
                    smoothedCents: tracked?.cents,
                    readingFrequency: tracked?.frequency,
                    inTune: tracked?.inTune ?? false
                ),
                publication: publication,
                confirmation: ParityConfirmationOutput(event: confirmed, stringIndex: tracked?.index, note: tracked?.note)
            ))
        }

        if let customFrames = config.customFrames {
            // Sparse windows with their own timestamps: no stream to reblock.
            for (index, custom) in customFrames.enumerated() {
                resetIfDue(before: index)
                var energy = 0.0
                for sample in custom.frame { energy += Double(sample) * Double(sample) }
                let rms = custom.frame.isEmpty ? 0.0 : sqrt(energy / Double(custom.frame.count))
                record(engine.analyse(FaithfulCaptureWindow(
                    frameIndex: index,
                    sampleIndex: Int(round((custom.timeMs / 1000.0) * sampleRate)),
                    timeMs: custom.timeMs,
                    workletTimeMs: custom.timeMs - workletOffsetMs,
                    hostTime: nil,
                    rms: rms,
                    samples: custom.frame,
                    sampleRate: sampleRate,
                    generation: 1
                )))
            }
        } else {
            // Delivered a hop at a time, so a settings change can land between two hops.
            let window = FaithfulCaptureFraming.windowSize
            let hop = FaithfulCaptureFraming.hopSize
            var start = 0
            var nextFrame = 0
            while start < samples.count {
                let end = min(start + (start == 0 ? window : hop), samples.count)
                if end - start == (start == 0 ? window : hop) { resetIfDue(before: nextFrame) }
                for analysed in engine.push(Array(samples[start..<end]), sampleRate: sampleRate) {
                    record(analysed)
                    nextFrame += 1
                }
                start = end
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

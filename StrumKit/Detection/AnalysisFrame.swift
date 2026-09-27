import Foundation

/// One window of audio offered to the analysis session, with the capture metadata
/// needed to place it in time and to judge whether it is still wanted: the rate it
/// was captured at, the timestamp of its *trailing* edge, the tap callback it
/// arrived in, and the generation it belongs to. `TunerAnalysisSession` drops a
/// frame whose `generation` is no longer current rather than analysing it, which
/// is what makes a configuration change safe while audio is in flight.
public struct AnalysisFrame: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    /// Denotes the timestamp at the trailing edge (end) of the analyzed audio window.
    public let captureEndSeconds: TimeInterval
    public let sequence: UInt64
    public let generation: UInt64
    public let callbackFrameCount: Int

    public init(
        samples: [Float],
        sampleRate: Double,
        captureEndSeconds: TimeInterval,
        sequence: UInt64,
        generation: UInt64,
        callbackFrameCount: Int = 0
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.captureEndSeconds = captureEndSeconds
        self.sequence = sequence
        self.generation = generation
        self.callbackFrameCount = callbackFrameCount
    }
}

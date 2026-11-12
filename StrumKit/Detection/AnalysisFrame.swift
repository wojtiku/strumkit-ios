import Foundation

/// One window of audio offered to the analysis session, with the capture metadata
/// needed to place it in time and to judge whether it is still wanted: the rate it
/// was captured at, the timestamp of its *trailing* edge, the tap callback it
/// arrived in, and the generation it belongs to. `TunerAnalysisSession` drops a
/// frame whose `generation` is no longer current rather than analysing it, which
/// is what makes a configuration change safe while audio is in flight.
struct AnalysisFrame: Sendable {
    let samples: [Float]
    let sampleRate: Double
    /// The trailing edge of the window on the *stream clock*: samples delivered since
    /// the stream began, divided by the sample rate. The tracker's cadence runs on this.
    let captureEndSeconds: TimeInterval
    /// The same trailing edge on the *host clock* (`CACurrentMediaTime`), or `nil` for a
    /// replay that has none. Every time on a published **Reading** is on this clock,
    /// because the display compares it with the host clock. See ADR 0001.
    let hostEndSeconds: TimeInterval?
    let sequence: UInt64
    let generation: UInt64
    let callbackFrameCount: Int

    init(
        samples: [Float],
        sampleRate: Double,
        captureEndSeconds: TimeInterval,
        sequence: UInt64,
        generation: UInt64,
        callbackFrameCount: Int = 0,
        hostEndSeconds: TimeInterval? = nil
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.captureEndSeconds = captureEndSeconds
        self.sequence = sequence
        self.generation = generation
        self.callbackFrameCount = callbackFrameCount
        self.hostEndSeconds = hostEndSeconds
    }
}

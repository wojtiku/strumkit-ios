import Foundation

/// One window of newly-captured audio.
public struct CapturedWindow: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    /// Host monotonic time of the window's *trailing edge*. The DSP's age maths
    /// (`resultAgeMs`) is measured from here, so it must not be a media timeline.
    public let captureEnd: TimeInterval

    public init(samples: [Float], sampleRate: Double, captureEnd: TimeInterval) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.captureEnd = captureEnd
    }
}

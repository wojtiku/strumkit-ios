import Foundation

/// One window of newly-captured audio.
struct CapturedWindow: Sendable {
    let samples: [Float]
    let sampleRate: Double
    /// Host monotonic time of the window's *trailing edge*. The DSP's age maths
    /// (`resultAgeMs`) is measured from here, so it must not be a media timeline.
    let captureEnd: TimeInterval

    init(samples: [Float], sampleRate: Double, captureEnd: TimeInterval) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.captureEnd = captureEnd
    }
}

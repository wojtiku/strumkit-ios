import Foundation

/// Pure presentation helper for tuning guidance, hold timeouts, and visual fading.
public enum TunerPresentation: Sendable {
    /// Visual hold duration before an inactive reading expires from the display.
    ///
    /// Kept equal to `PitchTracker.readingHoldDuration`: the tracker decides when a
    /// held reading stops being produced, and this decides when the display clears
    /// it. If they drift, the display and the tracker disagree about expiry.
    public static let displayHoldDuration: TimeInterval = PitchTracker.readingHoldDuration

    /// Minimum needle/readout opacity at the end of the display hold window.
    public static let minHoldOpacity: Double = 0.4

    /// Opacity used for a reading backed by spectral recovery rather than YIN.
    ///
    /// Recovery extends a note's life into the decay, but its cents error is
    /// larger than YIN's, so the value is shown de-emphasised and is never turned
    /// into tuning advice.
    public static let recoveredOpacity: Double = 0.55

    /// Returns human-readable guidance text for the current reading and feedback state.
    ///
    /// Fresh, YIN-confirmed readings display directional tuning advice
    /// ("In tune", "Tune up", "Tune down"). Held readings prompt for a new pluck,
    /// and spectrally recovered readings decline to give advice at all, since
    /// their cents error is not precise enough to act on.
    public static func guidanceText(for reading: TunerReading?, feedback: SignalFeedbackState) -> String {
        guard let reading else { return feedback.advisoryMessage }
        if reading.freshness == .held {
            return "Last reading — pluck again"
        }
        if reading.recovered {
            return "Still ringing — hold to check"
        }
        if reading.inTune {
            return "In tune"
        } else if reading.cents < 0 {
            return "Tune up"
        } else {
            return "Tune down"
        }
    }

    /// Computes needle/readout opacity fading from 1.0 to 0.4 over the display hold duration.
    /// Clamped to [minHoldOpacity, 1.0]. Fresh readings always return 1.0.
    public static func holdOpacity(for reading: TunerReading?, now: TimeInterval) -> Double {
        guard let reading else { return 1.0 }
        guard reading.freshness == .held else { return 1.0 }
        let elapsed = max(0.0, now - reading.lastFreshAt)
        let progress = min(1.0, elapsed / displayHoldDuration)
        let opacity = 1.0 - (1.0 - minHoldOpacity) * progress
        return max(minHoldOpacity, min(1.0, opacity))
    }
}

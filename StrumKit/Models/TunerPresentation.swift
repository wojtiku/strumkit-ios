import Foundation

/// Pure presentation helper for tuning guidance, hold timeouts, and visual fading.
public enum TunerPresentation: Sendable {
    /// Visual hold duration before an inactive reading expires from the display.
    public static let displayHoldDuration: TimeInterval = 1.0

    /// Minimum needle/readout opacity at the end of the display hold window.
    public static let minHoldOpacity: Double = 0.4

    /// Returns human-readable guidance text for the current reading and feedback state.
    ///
    /// Fresh readings display directional tuning advice ("In tune", "Tune up", "Tune down").
    /// Held readings prompt for a new pluck without misleading directional hints.
    public static func guidanceText(for reading: TunerReading?, feedback: SignalFeedbackState) -> String {
        guard let reading else { return feedback.advisoryMessage }
        if reading.freshness == .held {
            return "Last reading — pluck again"
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

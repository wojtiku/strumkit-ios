import Foundation

/// Pure presentation helper for tuning guidance, hold timeouts, and visual fading.
enum TunerPresentation: Sendable {
    /// Visual hold duration before an inactive reading expires from the display (1000 ms).
    static let displayHoldDuration: TimeInterval = 1.0

    /// Minimum needle/readout opacity at the end of the display hold window.
    static let minHoldOpacity: Double = 0.4

    /// Opacity used for a Reading backed by Sustained rather than Measured evidence.
    ///
    /// Sustained evidence extends a Note's life into the decay, but its cents error
    /// is larger than YIN's, so the value is shown de-emphasised and is never turned
    /// into tuning advice.
    static let sustainedOpacity: Double = 0.55

    /// Returns human-readable guidance text for the current reading and feedback state.
    ///
    /// Readings backed by Measured evidence display directional tuning advice
    /// ("In tune", "Hold the note…", "Tune up", "Tune down"). Held readings prompt for a new pluck,
    /// and Sustained readings decline to give advice at all, since
    /// their cents error is not precise enough to act on.
    ///
    /// A chromatic Reading is given no tuning advice either, for a different reason:
    /// there is no **String** for "turn the peg" to be about. It falls back to what the
    /// signal itself is saying, so the banner stays a report of the sound rather than
    /// becoming an instruction the mode cannot justify.
    static func guidanceText(for reading: TunerReading?, feedback: SignalFeedbackState) -> String {
        guard let reading else { return feedback.advisoryMessage }
        if reading.freshness == .held {
            return "Last reading — pluck again"
        }
        if reading.evidence == .sustained {
            return "Still ringing — hold to check"
        }
        guard case .target(_, let inTune) = reading.aim else {
            return feedback.advisoryMessage
        }
        if inTune {
            return "In tune"
        } else if abs(reading.displayCents) <= 5.0 {
            return "Hold the note…"
        } else if reading.displayCents < 0 {
            return "Tune up"
        } else {
            return "Tune down"
        }
    }

    /// What the readout prints opposite "HEARD": the thing the current Reading is
    /// measured against, and the name that is honest for it.
    ///
    /// The two cases get different labels, and that is the whole point. A **String** is
    /// something the player is trying to reach, so it is labelled TARGET and its
    /// frequency is the thing to aim at. The **Note** a chromatic Reading names is not
    /// a target and never was, so it is labelled EQUAL TEMP: the frequency the cents
    /// are a distance from, which is what a chromatic tuner is for.
    ///
    /// With nothing sounding, the second column falls back to what the mode is aiming
    /// at — the locked or guided String, or in chromatic mode simply "Nearest note",
    /// which is the only honest description of a pitch the player has not chosen.
    struct MeasuredAgainst: Equatable, Sendable {
        let label: String
        let value: String

        init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    static func measuredAgainst(
        for reading: TunerReading?,
        selectedTarget: StringTarget?,
        mode: TunerMode
    ) -> MeasuredAgainst {
        switch reading?.aim {
        case .target(let target, _):
            return MeasuredAgainst(label: "TARGET", value: "\(target.note) · \(formatHz(target.frequency))")
        case .note(let note):
            return MeasuredAgainst(label: "EQUAL TEMP", value: "\(note.displayName) · \(formatHz(note.frequency))")
        case nil:
            if mode == .chromatic {
                return MeasuredAgainst(label: "EQUAL TEMP", value: "Nearest note")
            }
            if let selectedTarget {
                return MeasuredAgainst(label: "TARGET", value: "\(selectedTarget.note) · \(formatHz(selectedTarget.frequency))")
            }
            return MeasuredAgainst(label: "TARGET", value: "Any open string")
        }
    }

    private static func formatHz(_ frequency: Double) -> String {
        String(format: "%.1f", frequency) + " Hz"
    }

    /// Computes needle/readout opacity fading from 1.0 to 0.4 over the display hold duration.
    /// Clamped to [minHoldOpacity, 1.0]. Fresh readings always return 1.0.
    static func holdOpacity(for reading: TunerReading?, now: TimeInterval) -> Double {
        guard let reading else { return 1.0 }
        guard reading.freshness == .held else { return 1.0 }
        let elapsed = max(0.0, now - reading.lastFreshAt)
        let progress = min(1.0, elapsed / displayHoldDuration)
        let opacity = 1.0 - (1.0 - minHoldOpacity) * progress
        return max(minHoldOpacity, min(1.0, opacity))
    }
}

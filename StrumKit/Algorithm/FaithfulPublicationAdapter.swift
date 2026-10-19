// StrumKit/Algorithm/FaithfulPublicationAdapter.swift
import Foundation

// MARK: - Faithful Presentation

/// Calm the display without reducing detector cadence or adding pitch latency.
///
/// Ported faithfully from `Tools/parity-contract/reference-source/presentation.ts`.
/// Throttles publication to at most 12 Hz (`time - lastDisplay < 1000.0 / 12.0`),
/// preserves the latest reading before throttling, and clears output to empty
/// after a 1000 ms display hold (`time - lastReading >= 1000.0`).
final class FaithfulPresentation: @unchecked Sendable {
    enum Action: Sendable, Equatable {
        case skipped
        case empty
        case published(reading: FaithfulReading, freshness: TunerReading.Freshness)

        var isSkipped: Bool {
            if case .skipped = self { return true }
            return false
        }

        var isEmpty: Bool {
            if case .empty = self { return true }
            return false
        }

        var isPublished: Bool {
            if case .published = self { return true }
            return false
        }

        var reading: FaithfulReading? {
            switch self {
            case .published(let r, _): return r
            default: return nil
            }
        }

        var freshness: TunerReading.Freshness? {
            switch self {
            case .published(_, let f): return f
            default: return nil
            }
        }
    }

    private(set) var latest: FaithfulReading? = nil
    private(set) var lastReading: Double = -.infinity
    private(set) var lastDisplay: Double = -.infinity
    private(set) var lastFreshTime: Double = -.infinity

    init() {}

    func reset() {
        latest = nil
        lastReading = -.infinity
        lastDisplay = -.infinity
        lastFreshTime = -.infinity
    }

    /// Throttles and holds reading frames.
    ///
    /// - Parameters:
    ///   - reading: Newly tracked reading, or `nil` if detector/tracker produced no reading on this frame.
    ///   - time: Frame timestamp in milliseconds.
    /// - Returns: `Action`:
    ///   - `.skipped` when frame rate exceeds 12 Hz (`time - lastDisplay < 1000.0 / 12.0`).
    ///   - `.empty` when hold has expired (`time - lastReading >= 1000.0`) or no reading exists.
    ///   - `.published(reading, freshness)` when ready for display. `freshness` is `.fresh` if a new reading arrived on this frame, or `.held` if published from hold.
    @discardableResult
    func push(reading: FaithfulReading?, time: Double) -> Action {
        let isFresh = (reading != nil)
        if let reading = reading {
            latest = reading
            lastReading = time
            lastFreshTime = time
        }
        if (time - lastDisplay) < (1000.0 / 12.0) {
            return .skipped
        }
        lastDisplay = time
        if (time - lastReading) >= 1000.0 {
            latest = nil
            return .empty
        }
        guard let currentLatest = latest else {
            return .empty
        }
        let freshness: TunerReading.Freshness = isFresh ? .fresh : .held
        return .published(reading: currentLatest, freshness: freshness)
    }
}

// MARK: - Faithful Reading Adapter

/// Adapts pure faithful algorithm outputs (from `FaithfulTracker`, `FaithfulPresentation`, and `TuningFeedback`)
/// into native domain models (`TunerReading`, `ReadingAim`, `Evidence`).
final class FaithfulReadingAdapter: @unchecked Sendable {
    let tracker: FaithfulTracker
    let presentation: FaithfulPresentation
    let feedback: TuningFeedback

    var mode: TunerMode
    var calibrationA4: Double = TunerConstants.defaultA4Hz
    var tuning: String {
        get { tracker.tuning }
        set { tracker.tuning = newValue }
    }
    var targets: [Target]? {
        get { tracker.targets }
        set { tracker.targets = newValue }
    }

    struct Output: Sendable, Equatable {
        var action: FaithfulPresentation.Action
        var reading: TunerReading?
        var completionEvent: Bool
        var completedStringIndex: Int?
        var completedNote: String?

        init(
            action: FaithfulPresentation.Action,
            reading: TunerReading?,
            completionEvent: Bool,
            completedStringIndex: Int? = nil,
            completedNote: String? = nil
        ) {
            self.action = action
            self.reading = reading
            self.completionEvent = completionEvent
            self.completedStringIndex = completedStringIndex
            self.completedNote = completedNote
        }
    }

    init(
        tracker: FaithfulTracker = FaithfulTracker(),
        presentation: FaithfulPresentation = FaithfulPresentation(),
        feedback: TuningFeedback = TuningFeedback(),
        mode: TunerMode = .auto,
        calibrationA4: Double = TunerConstants.defaultA4Hz
    ) {
        self.tracker = tracker
        self.presentation = presentation
        self.feedback = feedback
        self.mode = mode
        self.calibrationA4 = calibrationA4
    }

    func reset() {
        tracker.reset()
        presentation.reset()
        feedback.reset()
    }

    /// Adapts a `FaithfulReading` + detector context into a native `TunerReading`.
    static func adapt(
        reading: FaithfulReading,
        rawFrequency: Double? = nil,
        timeMs: Double,
        lastFreshTimeMs: Double,
        freshness: TunerReading.Freshness,
        targets: [Target],
        mode: TunerMode = .auto,
        evidence: Evidence? = nil,
        calibrationA4: Double = TunerConstants.defaultA4Hz
    ) -> TunerReading {
        let at = timeMs / 1000.0
        let lastFreshAt = lastFreshTimeMs / 1000.0
        let displayCents = reading.cents

        let targetObj: Target? = (reading.index >= 0 && reading.index < targets.count)
            ? targets[reading.index]
            : nil

        let reconstructedFrequency: Double
        if let target = targetObj {
            reconstructedFrequency = target.frequency * pow(2.0, displayCents / 1200.0)
        } else {
            reconstructedFrequency = reading.frequency
        }

        var centsVal: Double = displayCents
        var outputDisplayCents: Double = displayCents
        let resolvedEvidence = evidence ?? (freshness == .fresh ? .measured : .sustained)

        let aim: ReadingAim
        switch mode {
        case .chromatic:
            let queryFreq = rawFrequency ?? reconstructedFrequency
            if let closest = MusicalNote.closest(to: queryFreq, referenceA4: calibrationA4) {
                aim = .note(closest.note)
                centsVal = closest.cents
                outputDisplayCents = closest.cents
            } else if let closest = MusicalNote.closest(to: reconstructedFrequency, referenceA4: calibrationA4) {
                aim = .note(closest.note)
                centsVal = closest.cents
                outputDisplayCents = closest.cents
            } else if let target = targetObj {
                let note = MusicalNote(midiNoteNumber: target.midi, referenceA4: calibrationA4)
                aim = .note(note)
                let c = 1200.0 * log2(queryFreq / note.frequency)
                centsVal = c
                outputDisplayCents = c
            } else {
                let note = MusicalNote(midiNoteNumber: 60, referenceA4: calibrationA4)
                aim = .note(note)
                centsVal = 0.0
                outputDisplayCents = 0.0
            }
        default:
            if let rawFreq = rawFrequency, rawFreq > 0, let target = targetObj, target.frequency > 0 {
                centsVal = centsBetween(frequency: rawFreq, reference: target.frequency)
            } else {
                centsVal = displayCents
            }
            if let target = targetObj {
                let stringTarget = StringTarget(
                    note: target.note,
                    midi: target.midi,
                    frequency: target.frequency,
                    number: reading.stringNumber
                )
                aim = .target(stringTarget, inTune: reading.inTune)
            } else {
                let fallbackTarget = StringTarget(
                    note: reading.note,
                    midi: 60,
                    frequency: reading.frequency,
                    number: reading.stringNumber
                )
                aim = .target(fallbackTarget, inTune: reading.inTune)
            }
        }

        return TunerReading(
            at: at,
            lastFreshAt: lastFreshAt,
            frequency: reconstructedFrequency,
            aim: aim,
            cents: centsVal,
            displayCents: outputDisplayCents,
            freshness: freshness,
            evidence: resolvedEvidence
        )
    }

    /// Processes a detector pitch candidate frame.
    ///
    /// Observes completion at tracker cadence BEFORE the 12 Hz throttle.
    func process(
        candidate: FaithfulPitchCandidate?,
        timeMs: Double
    ) -> Output {
        // 1. Tracker cadence
        let tracked = tracker.push(pitch: candidate, time: timeMs)

        // 2. Observe completion at tracker cadence BEFORE 12 Hz throttle
        let completed = feedback.observe(tracked)
        let completedIndex = completed ? tracked?.index : nil
        let completedNote = completed ? tracked?.note : nil

        // 3. Presentation 12 Hz throttle & 1-second hold
        let action = presentation.push(reading: tracked, time: timeMs)

        // 4. Adapt to native TunerReading if published
        let nativeReading: TunerReading?
        switch action {
        case .published(let pubReading, let freshness):
            let targets = tracker.currentTargets
            nativeReading = Self.adapt(
                reading: pubReading,
                rawFrequency: (freshness == .fresh ? candidate?.frequency : nil),
                timeMs: timeMs,
                lastFreshTimeMs: presentation.lastFreshTime,
                freshness: freshness,
                targets: targets,
                mode: mode,
                calibrationA4: calibrationA4
            )
        case .skipped, .empty:
            nativeReading = nil
        }

        return Output(
            action: action,
            reading: nativeReading,
            completionEvent: completed,
            completedStringIndex: completedIndex,
            completedNote: completedNote
        )
    }

    /// Processes an already tracked reading directly.
    ///
    /// Observes completion at tracker cadence BEFORE the 12 Hz throttle.
    func process(
        reading: FaithfulReading?,
        rawFrequency: Double? = nil,
        timeMs: Double
    ) -> Output {
        // 1. Observe completion at tracker cadence BEFORE 12 Hz throttle
        let completed = feedback.observe(reading)
        let completedIndex = completed ? reading?.index : nil
        let completedNote = completed ? reading?.note : nil

        // 2. Presentation 12 Hz throttle & 1-second hold
        let action = presentation.push(reading: reading, time: timeMs)

        // 3. Adapt to native TunerReading if published
        let nativeReading: TunerReading?
        switch action {
        case .published(let pubReading, let freshness):
            let targets = TUNINGS[tracker.tuning] ?? TUNINGS["standard"]!
            nativeReading = Self.adapt(
                reading: pubReading,
                rawFrequency: (freshness == .fresh ? rawFrequency : nil),
                timeMs: timeMs,
                lastFreshTimeMs: presentation.lastFreshTime,
                freshness: freshness,
                targets: targets,
                mode: mode
            )
        case .skipped, .empty:
            nativeReading = nil
        }

        return Output(
            action: action,
            reading: nativeReading,
            completionEvent: completed,
            completedStringIndex: completedIndex,
            completedNote: completedNote
        )
    }
}

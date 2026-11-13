import Foundation

/// Turns captured audio into **Readings**.
///
/// The whole path lives here and nowhere else: reblocking audio into hops, finding the
/// note that is sounding, measuring its pitch, tracking it against the **Targets**,
/// confirming a **String** in tune, holding the last **Reading** for a second, crediting
/// guided progress, and naming the result in the domain's terms.
///
/// There are two ways through. `.precise` is what the app runs: the detector says which
/// note is sounding, the partial lock measures how fast the string is actually vibrating,
/// and the reading tracker follows that. `.reference` is the web tuner's path, kept
/// bit-for-bit so the parity suite can go on proving the port; the detector's own
/// frequency goes straight to the reference tracker and the display is throttled to 12 Hz
/// as the reference's is.
///
/// The engine is synchronous and owns no thread and no lock. Whoever drives it must do
/// so from one place at a time; in the app that is the analysis session's worker.
///
/// Two clocks, kept apart (ADR 0001). The *stream clock* — samples delivered since the
/// stream began, over the sample rate — drives every timer in here and never leaves.
/// Every time on a **Reading** that comes out is on the *host clock*, taken from the
/// capture timestamps that came in.
final class ReadingEngine {
    /// What the engine is listening for: everything that changes what is heard, and
    /// nothing that only changes how it is shown.
    enum Pipeline: Sendable, Equatable {
        case precise
        case reference
    }

    struct Configuration: Sendable, Equatable {
        var profile: FaithfulEngineProfile
        var targets: [StringTarget]
        var calibrationA4: Double
        var mode: TunerMode
        /// The locked **String**, as an index into `targets`. Read only in `.manual`.
        var selectedString: Int

        init(
            profile: FaithfulEngineProfile,
            targets: [StringTarget],
            calibrationA4: Double = TunerConstants.defaultA4Hz,
            mode: TunerMode = .auto,
            selectedString: Int = 0
        ) {
            self.profile = profile
            self.targets = targets
            self.calibrationA4 = calibrationA4
            self.mode = mode
            self.selectedString = selectedString
        }

        init(config: TunerConfig, targets: [StringTarget]) {
            self.init(
                profile: FaithfulEngineProfile.profile(for: config.instrument, tuningId: config.tuningId),
                targets: targets,
                calibrationA4: config.a4,
                mode: config.mode,
                selectedString: config.selectedString
            )
        }

        init(_ resolved: Tuning.Resolved) {
            self.init(config: resolved.config, targets: resolved.targets)
        }
    }

    /// What one hop of audio amounted to.
    struct Hop: Sendable, Equatable {
        /// What the display should do about it.
        enum Display: Sendable, Equatable {
            /// Nothing: the display was updated less than a twelfth of a second ago.
            case unchanged
            /// Show nothing: no **Reading**, and no **Held reading** left to show.
            case cleared
            /// Show this.
            case reading(TunerReading)

            var reading: TunerReading? {
                if case .reading(let reading) = self { return reading }
                return nil
            }
        }

        let display: Display
        let feedback: SignalFeedbackState
        let guidedProgress: [Bool]
        let guidedTargetIndex: Int
        /// The index of the **String** this hop completed in the guided sequence, if any.
        let completedString: Int?
        /// The **Level** of what was heard, or of the input when nothing was.
        let level: Double
        let trace: Trace
    }

    /// The engine's intermediate results for one hop, on the stream clock.
    ///
    /// For measurement, not for display: the parity suite compares these against the
    /// reference, and nothing in the app reads them.
    struct Trace: Sendable, Equatable {
        let frameIndex: Int
        let sampleIndex: Int
        let streamTimeMs: Double
        let workletTimeMs: Double
        let windowRMS: Double
        let candidate: FaithfulPitchCandidate?
        let tracked: FaithfulReading?
        let publication: FaithfulPresentation.Action
    }

    private(set) var configuration: Configuration
    let pipeline: Pipeline
    /// How many times the stream has been restarted because audio was lost.
    private(set) var discontinuityCount: Int = 0

    var sampleRate: Double { framer.sampleRate }
    var guidedProgress: [Bool] { guided.progress }
    var guidedTargetIndex: Int { guided.currentTargetIndex }

    private let framer: FaithfulCaptureFraming
    private var detector: FaithfulStreamingDetector
    private let tracker = FaithfulTracker()
    private let presentation: FaithfulPresentation
    private let lock = PartialLock()
    private let readingTracker = ReadingTracker()
    /// The most recent audio, newest last: what the partial lock measures over, which is
    /// longer than one detector window.
    private var history: [Float] = []
    /// The **Notes** a chromatic **Reading** may name, as the tracker's targets.
    private var chromaticNotes: [Target] = []
    private var guided: FaithfulGuidedSequence
    /// Host time of the hop that last produced a fresh reading.
    private var lastFreshHost: TimeInterval?

    /// The largest piece handed to the framer at once. Keeps any chunk size inside the
    /// framer's buffer, so a long replay is not mistaken for an overload.
    private static let maxPiece = FaithfulCaptureFraming.windowSize

    init(configuration: Configuration, sampleRate: Double = 44100.0, pipeline: Pipeline = .precise) {
        self.configuration = configuration
        self.pipeline = pipeline
        // The needle is drawn at the display's own rate from whatever arrives, so the
        // precise path tells it everything; the reference keeps its 12 Hz.
        self.presentation = FaithfulPresentation(minimumIntervalMs: pipeline == .precise ? 0.0 : 1000.0 / 12.0)
        self.framer = FaithfulCaptureFraming(sampleRate: sampleRate)
        self.detector = createPitchDetector(profile: configuration.profile)
        self.guided = FaithfulGuidedSequence(targetCount: configuration.targets.count)
        applyToTracker(configuration)
    }

    // MARK: - Configuration

    /// Changes what the engine is listening for.
    ///
    /// The audio stream carries on: nothing buffered is thrown away and the detector
    /// keeps its history unless the frequency range it works in has changed. What is
    /// forgotten is the **Reading** — the tracked **String**, the smoothing, the in-tune
    /// confirmation and anything held on the display — because all of it was measured
    /// against what the engine was listening for before.
    func configure(_ new: Configuration, preservingGuidedProgress: Bool = false) {
        if new.profile != configuration.profile {
            detector = createPitchDetector(profile: new.profile)
        }
        if !preservingGuidedProgress || new.targets.count != guided.targetCount {
            guided = FaithfulGuidedSequence(targetCount: new.targets.count)
        }
        configuration = new
        applyToTracker(new)
        forgetReading()
    }

    /// Starts the guided sequence again from its first **String**.
    func restartGuidedSequence() {
        guided.reset()
    }

    /// Tells the engine that audio was lost between the last push and the next one.
    ///
    /// Everything that assumed an unbroken stream starts again: the buffered audio, the
    /// detector's history, the tracked **Reading**. Guided progress is the player's and
    /// survives. See ADR 0002.
    func discontinuity() {
        discontinuityCount += 1
        framer.reset()
        detector = createPitchDetector(profile: configuration.profile)
        history.removeAll(keepingCapacity: true)
        lock.reset()
        forgetReading()
    }

    private func forgetReading() {
        tracker.reset()
        readingTracker.reset()
        presentation.reset()
        lastFreshHost = nil
    }

    /// The one place the domain's **Targets** become the tracker's.
    private func applyToTracker(_ configuration: Configuration) {
        tracker.targets = configuration.targets.map {
            Target(note: $0.note, frequency: $0.frequency, midi: $0.midi, stringNumber: $0.number)
        }
        tracker.auto = configuration.mode != .manual
        tracker.selected = configuration.selectedString

        if configuration.mode == .chromatic {
            // Nothing is being aimed at, so every Note the detector can hear is a
            // candidate and the nearest one is named.
            let a4 = configuration.calibrationA4
            let lowest = Int((69.0 + 12.0 * log2(configuration.profile.minFrequency / a4)).rounded(.up))
            let highest = Int((69.0 + 12.0 * log2(configuration.profile.maxFrequency / a4)).rounded(.down))
            chromaticNotes = (lowest...max(lowest, highest)).map {
                Target(note: PitchMath.midiNoteName($0), frequency: PitchMath.midiFrequency($0, a4: a4), midi: $0)
            }
            readingTracker.targets = chromaticNotes
            readingTracker.auto = true
        } else {
            chromaticNotes = []
            readingTracker.targets = tracker.targets ?? []
            readingTracker.auto = configuration.mode != .manual
        }
        readingTracker.selected = configuration.selectedString
    }

    // MARK: - Audio in, hops out

    /// Takes the next stretch of captured audio, of any length, and returns one `Hop`
    /// for each 1024-sample hop it completed — none, one, or several.
    ///
    /// - Parameter hostEnd: host-clock time of the *last* sample, or `nil` for a replay
    ///   with no host clock, in which case **Reading** times are stream times.
    func push(_ samples: [Float], sampleRate: Double, hostEnd: TimeInterval? = nil) -> [Hop] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }

        if sampleRate != framer.sampleRate {
            // A different rate is a different stream.
            framer.setSampleRate(sampleRate)
            detector = createPitchDetector(profile: configuration.profile)
            history.removeAll(keepingCapacity: true)
            lock.reset()
            forgetReading()
        }

        if samples.count <= Self.maxPiece {
            return framer.process(channel: samples, hostTime: hostEnd).map(analyse)
        }

        var hops: [Hop] = []
        var start = 0
        while start < samples.count {
            let end = min(start + Self.maxPiece, samples.count)
            let pieceHostEnd = hostEnd.map { $0 - Double(samples.count - end) / sampleRate }
            let windows = framer.process(channel: Array(samples[start..<end]), hostTime: pieceHostEnd)
            hops.append(contentsOf: windows.map(analyse))
            start = end
        }
        return hops
    }

    /// Analyses one already-framed window at a stated stream time.
    ///
    /// The framer's output goes through here, and so does a replay that supplies its own
    /// sparse windows and timestamps instead of a continuous stream.
    func analyse(_ window: FaithfulCaptureWindow) -> Hop {
        let timeMs = window.timeMs
        let host = window.hostTime ?? (timeMs / 1000.0)

        let candidate = detector.detect(input: window.samples, sampleRate: window.sampleRate, sampleTime: timeMs)
        let tracked: FaithfulReading?
        switch pipeline {
        case .reference:
            tracked = tracker.push(pitch: candidate, time: timeMs)
        case .precise:
            remember(window)
            // The detector names the note; the lock measures it.
            let note = candidate.flatMap { $0.confidence >= 0.75 ? $0.frequency : nil }
            let measured = lock.measure(
                history: history[...],
                sampleRate: window.sampleRate,
                coarse: note,
                range: configuration.profile.minFrequency...configuration.profile.maxFrequency,
                timeMs: timeMs)
            tracked = readingTracker.push(
                frequency: measured?.frequency,
                rms: candidate?.rms ?? window.rms,
                time: timeMs)
        }

        // Completion is decided here, at tracker cadence, before the display throttle
        // gets to decide whether this hop is shown at all.
        var completedString: Int?
        if configuration.mode == .guided, guided.observe(reading: tracked) {
            completedString = tracked?.index
        }

        if tracked != nil { lastFreshHost = host }
        let publication = presentation.push(reading: tracked, time: timeMs)

        let display: Hop.Display
        switch publication {
        case .skipped:
            display = .unchanged
        case .empty:
            display = .cleared
        case .published(let published, let freshness):
            let reading = makeReading(
                published,
                // On the precise path the detector's own frequency is only where the lock
                // was told to look; the tracked value is the measurement.
                rawFrequency: pipeline == .reference && freshness == .fresh ? candidate?.frequency : nil,
                freshness: freshness,
                at: host
            )
            display = reading.map(Hop.Display.reading) ?? .cleared
        }

        let feedback: SignalFeedbackState
        if display.reading != nil {
            feedback = .tracking
        } else if candidate != nil {
            feedback = .checking
        } else {
            feedback = .ready
        }

        return Hop(
            display: display,
            feedback: feedback,
            guidedProgress: guided.progress,
            guidedTargetIndex: guided.currentTargetIndex,
            completedString: completedString,
            level: candidate?.rms ?? window.rms,
            trace: Trace(
                frameIndex: window.frameIndex,
                sampleIndex: window.sampleIndex,
                streamTimeMs: timeMs,
                workletTimeMs: window.workletTimeMs,
                windowRMS: window.rms,
                candidate: candidate,
                tracked: tracked,
                publication: publication
            )
        )
    }

    /// Keeps the newest audio for the partial lock. Windows overlap, so after the first
    /// only each one's last hop is new.
    private func remember(_ window: FaithfulCaptureWindow) {
        let keep = Int(window.sampleRate * 0.25)
        if history.isEmpty {
            history.append(contentsOf: window.samples)
        } else {
            history.append(contentsOf: window.samples.suffix(FaithfulCaptureFraming.hopSize))
        }
        if history.count > keep * 2 {
            history.removeFirst(history.count - keep)
        }
    }

    // MARK: - Naming the result

    /// Names a tracked reading in the domain's terms, or returns `nil` when it points
    /// at a **String** the current **Tuning** does not have. Nothing is invented to fill
    /// the gap.
    private func makeReading(
        _ tracked: FaithfulReading,
        rawFrequency: Double?,
        freshness: TunerReading.Freshness,
        at host: TimeInterval
    ) -> TunerReading? {
        if pipeline == .precise, configuration.mode == .chromatic {
            guard chromaticNotes.indices.contains(tracked.index) else { return nil }
            let note = MusicalNote(midiNoteNumber: chromaticNotes[tracked.index].midi, referenceA4: configuration.calibrationA4)
            return TunerReading(
                at: host,
                lastFreshAt: lastFreshHost ?? host,
                frequency: tracked.frequency,
                aim: .note(note),
                cents: tracked.cents,
                displayCents: tracked.cents,
                freshness: freshness,
                evidence: freshness == .fresh ? .measured : .sustained
            )
        }

        guard configuration.targets.indices.contains(tracked.index) else { return nil }
        let target = configuration.targets[tracked.index]

        // The smoothed pitch, as a frequency: where the needle is, not the raw estimate.
        let frequency = target.frequency * pow(2.0, tracked.cents / 1200.0)

        let aim: ReadingAim
        let cents: Double
        let displayCents: Double
        if configuration.mode == .chromatic {
            // Nothing is being aimed at, so the **Note** is whichever is nearest to what
            // was heard, and the cents are its distance from equal temperament.
            guard let closest = MusicalNote.closest(to: rawFrequency ?? frequency, referenceA4: configuration.calibrationA4)
                ?? MusicalNote.closest(to: frequency, referenceA4: configuration.calibrationA4)
            else { return nil }
            aim = .note(closest.note)
            cents = closest.cents
            displayCents = closest.cents
        } else {
            aim = .target(target, inTune: tracked.inTune)
            if let rawFrequency, rawFrequency > 0, target.frequency > 0 {
                cents = centsBetween(frequency: rawFrequency, reference: target.frequency)
            } else {
                cents = tracked.cents
            }
            displayCents = tracked.cents
        }

        return TunerReading(
            at: host,
            lastFreshAt: lastFreshHost ?? host,
            frequency: frequency,
            aim: aim,
            cents: cents,
            displayCents: displayCents,
            freshness: freshness,
            // A fresh reading was measured in this window; a held one is the memory of
            // a measurement, and is graded as such.
            evidence: freshness == .fresh ? .measured : .sustained
        )
    }
}

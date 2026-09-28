import Testing
import Foundation
import QuartzCore
@testable import StrumKit

@Suite("Tuner Presentation Tests")
struct TunerPresentationTests {

    private static let a4Target = StringTarget(note: "A4", midi: 69, frequency: 440.0, number: 1)

    private func makeReading(
        at: TimeInterval = 10.0,
        lastFreshAt: TimeInterval = 10.0,
        frequency: Double = 440.0,
        cents: Double = 0.0,
        freshness: TunerReading.Freshness = .fresh,
        inTune: Bool = true,
        evidence: Evidence = .measured
    ) -> TunerReading {
        TunerReading(
            at: at,
            lastFreshAt: lastFreshAt,
            frequency: frequency,
            aim: .target(Self.a4Target, inTune: inTune),
            cents: cents,
            displayCents: cents,
            freshness: freshness,
            evidence: evidence
        )
    }

    /// A chromatic Reading: a Note in equal temperament, and nothing to be in tune
    /// with. Built the way `PitchTracker` builds one, so a test claiming chromatic
    /// mode has no Target is claiming it about the value the display receives.
    private func makeChromaticReading(
        at: TimeInterval = 10.0,
        midi: Int = 69,
        frequency: Double = 440.0,
        cents: Double = 0.0,
        freshness: TunerReading.Freshness = .fresh,
        evidence: Evidence = .measured
    ) -> TunerReading {
        TunerReading(
            at: at,
            lastFreshAt: at,
            frequency: frequency,
            aim: .note(MusicalNote(midiNoteNumber: midi)),
            cents: cents,
            displayCents: cents,
            freshness: freshness,
            evidence: evidence
        )
    }

    @Test("Guidance text returns advisory message when reading is nil")
    func testGuidanceTextNilReading() {
        let text = TunerPresentation.guidanceText(for: nil, feedback: .ready)
        #expect(text == SignalFeedbackState.ready.advisoryMessage)

        let quietText = TunerPresentation.guidanceText(for: nil, feedback: .quiet)
        #expect(quietText == SignalFeedbackState.quiet.advisoryMessage)
    }

    @Test("Guidance text for held reading always prompts to pluck again")
    func testGuidanceTextHeldReading() {
        // Even if in-tune or detuned, held reading must never give directional advice
        let heldInTune = makeReading(freshness: .held, inTune: true)
        #expect(TunerPresentation.guidanceText(for: heldInTune, feedback: .tracking) == "Last reading — pluck again")

        let heldFlat = makeReading(cents: -15.0, freshness: .held, inTune: false)
        #expect(TunerPresentation.guidanceText(for: heldFlat, feedback: .tracking) == "Last reading — pluck again")

        let heldSharp = makeReading(cents: 20.0, freshness: .held, inTune: false)
        #expect(TunerPresentation.guidanceText(for: heldSharp, feedback: .tracking) == "Last reading — pluck again")
    }

    @Test("Guidance text for fresh readings gives accurate directional hints")
    func testGuidanceTextFreshReadings() {
        let freshInTune = makeReading(cents: 1.0, freshness: .fresh, inTune: true)
        #expect(TunerPresentation.guidanceText(for: freshInTune, feedback: .tracking) == "In tune")

        let freshFlat = makeReading(cents: -8.0, freshness: .fresh, inTune: false)
        #expect(TunerPresentation.guidanceText(for: freshFlat, feedback: .tracking) == "Tune up")

        let freshSharp = makeReading(cents: 12.0, freshness: .fresh, inTune: false)
        #expect(TunerPresentation.guidanceText(for: freshSharp, feedback: .tracking) == "Tune down")
    }

    @Test("Hold opacity is 1.0 for nil and fresh readings")
    func testHoldOpacityNilAndFresh() {
        #expect(TunerPresentation.holdOpacity(for: nil, now: 10.0) == 1.0)

        let fresh = makeReading(at: 10.0, lastFreshAt: 10.0, freshness: .fresh)
        #expect(TunerPresentation.holdOpacity(for: fresh, now: 10.5) == 1.0)
    }

    @Test("Hold opacity fades linearly from 1.0 to 0.4 over display hold duration")
    func testHoldOpacityHeldFading() {
        let held = makeReading(at: 10.5, lastFreshAt: 10.0, freshness: .held)

        // At onset of hold (elapsed = 0.0): opacity = 1.0
        let atZero = TunerPresentation.holdOpacity(for: held, now: 10.0)
        #expect(abs(atZero - 1.0) < 1e-4)

        // At halfway (elapsed = 0.5s): opacity = 0.7
        let atHalf = TunerPresentation.holdOpacity(for: held, now: 10.5)
        #expect(abs(atHalf - 0.7) < 1e-4)

        // At expiration edge (elapsed = 1.0s): opacity = 0.4
        let atFull = TunerPresentation.holdOpacity(for: held, now: 11.0)
        #expect(abs(atFull - 0.4) < 1e-4)

        // Past expiration (elapsed = 1.5s): clamped to minHoldOpacity 0.4
        let pastExpiry = TunerPresentation.holdOpacity(for: held, now: 11.5)
        #expect(abs(pastExpiry - 0.4) < 1e-4)

        // Negative elapsed (e.g. clock adjustment): clamped to 1.0
        let negativeElapsed = TunerPresentation.holdOpacity(for: held, now: 9.9)
        #expect(abs(negativeElapsed - 1.0) < 1e-4)
    }

    @Test("Guidance text for Sustained readings declines to give tuning advice")
    func testGuidanceTextSustainedReading() {
        let inTune = makeReading(freshness: .fresh, inTune: false, evidence: .sustained)
        #expect(TunerPresentation.guidanceText(for: inTune, feedback: .tracking) == "Still ringing — hold to check")

        let flat = makeReading(cents: -30.0, freshness: .fresh, inTune: false, evidence: .sustained)
        #expect(TunerPresentation.guidanceText(for: flat, feedback: .tracking) == "Still ringing — hold to check",
                "A 30-cent-flat Sustained frame must not tell the player to turn a peg")

        let sharp = makeReading(cents: 25.0, freshness: .fresh, inTune: false, evidence: .sustained)
        #expect(TunerPresentation.guidanceText(for: sharp, feedback: .tracking) == "Still ringing — hold to check")
    }

    // MARK: - Target or Note, never both

    @Test("A chromatic Reading gets no tuning advice, because no String is being aimed at")
    func testChromaticReadingIsGivenNoTuningAdvice() {
        // Both directions, and both magnitudes: whatever the cents say, there is no peg
        // to point at. Before the split, each of these read `inTune == false` and
        // produced "Tune up" / "Tune down" about a string the mode never chose.
        let flat = makeChromaticReading(cents: -8.0)
        #expect(TunerPresentation.guidanceText(for: flat, feedback: .tracking) == SignalFeedbackState.tracking.advisoryMessage,
                "A chromatic Reading is 8 cents flat of equal temperament; it is not a string that needs tightening")

        let sharp = makeChromaticReading(cents: 12.0)
        #expect(TunerPresentation.guidanceText(for: sharp, feedback: .tracking) == SignalFeedbackState.tracking.advisoryMessage,
                "A chromatic Reading is 12 cents sharp of equal temperament; that is a fact, not an instruction")

        // Dead on equal temperament is not "in tune" either — there is no String.
        let centred = makeChromaticReading(cents: 0.0)
        #expect(TunerPresentation.guidanceText(for: centred, feedback: .tracking) != "In tune",
                "Nothing was aimed at, so nothing can have been reached")

        // The banner still reports the signal, so it does not go blank.
        #expect(TunerPresentation.guidanceText(for: sharp, feedback: .quiet) == SignalFeedbackState.quiet.advisoryMessage)
    }

    @Test("A held or sustained chromatic Reading is reported the same way as any other")
    func testChromaticHeldAndSustainedGuidanceUnchanged() {
        // These two are about Evidence and about the hold, not about the mode, so they
        // must keep their existing text: nothing here is advice about a String either.
        let held = makeChromaticReading(freshness: .held)
        #expect(TunerPresentation.guidanceText(for: held, feedback: .tracking) == "Last reading — pluck again")

        let sustained = TunerReading(
            at: 10.0,
            lastFreshAt: 10.0,
            frequency: 440.0,
            aim: .note(MusicalNote(midiNoteNumber: 69)),
            cents: -30.0,
            displayCents: -30.0,
            freshness: .fresh,
            evidence: .sustained
        )
        #expect(TunerPresentation.guidanceText(for: sustained, feedback: .tracking) == "Still ringing — hold to check")
    }

    @Test("The readout names a String as TARGET and a Note as EQUAL TEMP")
    func testMeasuredAgainstLabelsEachKindHonestly() {
        let target = StringTarget(note: "A4", midi: 69, frequency: 440.0, number: 1)

        // A Reading measured against a String: that is what the player is aiming at.
        let withTarget = TunerPresentation.measuredAgainst(
            for: makeReading(cents: 3.0), selectedTarget: nil, mode: .auto)
        #expect(withTarget.label == "TARGET")
        #expect(withTarget.value == "A4 · 440.0 Hz")

        // A chromatic Reading: the equal-tempered Note is what the cents are a
        // distance from. It is not a target, and calling it one is the claim this split
        // exists to remove — so the column says EQUAL TEMP even though a String was
        // previously selected and would otherwise be the obvious thing to print.
        let withNote = TunerPresentation.measuredAgainst(
            for: makeChromaticReading(midi: 64, frequency: 323.0, cents: 3.0), selectedTarget: target, mode: .chromatic)
        #expect(withNote.label == "EQUAL TEMP")
        #expect(withNote.value == "E4 · 329.6 Hz",
                "The Note's own frequency under the calibration is the reference, even when a String was previously selected")

        // Nothing sounding: the String the mode is aiming at, or in chromatic mode the
        // nearest Note, which is the only pitch the mode can name on its own.
        #expect(TunerPresentation.measuredAgainst(for: nil, selectedTarget: target, mode: .manual)
            == TunerPresentation.MeasuredAgainst(label: "TARGET", value: "A4 · 440.0 Hz"))
        #expect(TunerPresentation.measuredAgainst(for: nil, selectedTarget: target, mode: .chromatic)
            == TunerPresentation.MeasuredAgainst(label: "EQUAL TEMP", value: "Nearest note"),
            "A chromatic Reading's absence must not fall back to naming a String")
        #expect(TunerPresentation.measuredAgainst(for: nil, selectedTarget: nil, mode: .auto)
            == TunerPresentation.MeasuredAgainst(label: "TARGET", value: "Any open string"))
    }

    @Test("A Reading names one thing only, and the type says which")
    func testReadingAimIsExclusive() {
        let target = StringTarget(note: "A4", midi: 69, frequency: 440.0, number: 1)
        let note = MusicalNote(midiNoteNumber: 69)

        #expect(ReadingAim.target(target, inTune: true).target == target)
        #expect(ReadingAim.target(target, inTune: true).inTune == true)
        if case .note = ReadingAim.target(target, inTune: true) {
            Issue.record("A String-mode Reading must not also be a Note")
        }

        #expect(ReadingAim.note(note).target == nil)
        #expect(ReadingAim.note(note).inTune == nil)
        if case .target = ReadingAim.note(note) {
            Issue.record("A chromatic Reading must not also be a Target")
        }

        // Both name the same pitch, which is exactly why one field could not carry both.
        #expect(ReadingAim.target(target, inTune: true).name == ReadingAim.note(note).name)
        #expect(ReadingAim.target(target, inTune: true) != ReadingAim.note(note))
    }

    @Test("Recovered opacity is dimmer than fresh and dimmer than a hold in progress")
    func testRecoveredOpacityIsDistinct() {
        #expect(TunerPresentation.sustainedOpacity < 1.0)
        #expect(TunerPresentation.sustainedOpacity > TunerPresentation.minHoldOpacity,
                "Recovered evidence should still be clearly visible")
    }

    @Test("Display hold duration tracks the tracker's hold duration")
    func testDisplayHoldMatchesTrackerHold() {
        #expect(TunerPresentation.displayHoldDuration == PitchTracker.readingHoldDuration,
                "The tracker decides when a held reading stops; the view must expire it at the same moment")
    }

    @Test("TunerViewModel dims the needle for Sustained evidence")
    @MainActor
    func testViewModelNeedleOpacityForSustainedReading() {
        let session = TunerAnalysisSession()
        let vm = TestTuner.viewModel(session: session)
        let now = CACurrentMediaTime()

        let sustained = TunerReading(
            at: now,
            lastFreshAt: now,
            frequency: 440.0,
            aim: .target(Self.a4Target, inTune: false),
            cents: -12.0,
            displayCents: -12.0,
            freshness: .fresh,
            evidence: .sustained
        )
        let snap = AnalysisSnapshot(
            reading: sustained,
            pitchResult: PitchResult(frequency: 440.0, closestNote: MusicalNote(midiNoteNumber: 69), centsDeviation: -12, confidence: 0.2, amplitudeRMS: 0.002, isSignalPresent: true, evidence: .sustained),
            feedbackState: .tracking,
            guidedProgress: [],
            guidedTargetIndex: 0,
            diagnostics: TunerDiagnostics(),
            generation: session.generation,
            sequence: 1
        )

        vm.handleSnapshot(snap)
        #expect(vm.currentReading?.evidence == .sustained)
        // The Reading is Fresh, so the fade the display derives is 1.0 and the only
        // thing dimming the needle is the Evidence behind it.
        #expect(vm.needleOpacity(holdFade: 1.0) == TunerPresentation.sustainedOpacity)
    }

    @Test("TunerViewModel hold presentation retains reading without premature expiration")
    @MainActor
    func testViewModelHoldPresentationRetainsReadingWithoutPrematureExpiration() async throws {
        let session = TunerAnalysisSession()
        let vm = TestTuner.viewModel(session: session)

        let now = CACurrentMediaTime()
        let freshReading = TunerReading(
            at: now,
            lastFreshAt: now,
            frequency: 440.0,
            aim: .target(Self.a4Target, inTune: true),
            cents: 0.0,
            displayCents: 0.0,
            freshness: .fresh,
            evidence: .measured
        )

        let freshSnap = AnalysisSnapshot(
            reading: freshReading,
            pitchResult: PitchResult(frequency: 440.0, closestNote: MusicalNote(midiNoteNumber: 69), centsDeviation: 0, confidence: 0.9, amplitudeRMS: 0.05, isSignalPresent: true, evidence: .measured),
            feedbackState: .tracking,
            guidedProgress: [],
            guidedTargetIndex: 0,
            diagnostics: TunerDiagnostics(),
            generation: session.generation,
            sequence: 1
        )

        vm.handleSnapshot(freshSnap)
        #expect(vm.currentReading != nil)
        #expect(vm.currentReading?.freshness == .fresh)
        // The fade is the display's to derive now, from the timeline. What is asserted
        // here is the value the display will derive, which is the same policy the
        // presentation layer has always been asked for.
        #expect(TunerPresentation.holdOpacity(for: vm.currentReading, now: CACurrentMediaTime()) == 1.0)

        // Now deliver a held reading with fresh timestamp right at the start of hold
        let heldNow = CACurrentMediaTime()
        let heldReading = TunerReading(
            at: heldNow,
            lastFreshAt: heldNow,
            frequency: 440.0,
            aim: .target(Self.a4Target, inTune: true),
            cents: 0.0,
            displayCents: 0.0,
            freshness: .held,
            evidence: .measured
        )

        let heldSnap = AnalysisSnapshot(
            reading: heldReading,
            pitchResult: PitchResult(frequency: 0, closestNote: MusicalNote(midiNoteNumber: 69), centsDeviation: 0, confidence: 0, amplitudeRMS: 0.001, isSignalPresent: false, evidence: .measured),
            feedbackState: .tracking,
            guidedProgress: [],
            guidedTargetIndex: 0,
            diagnostics: TunerDiagnostics(),
            generation: session.generation,
            sequence: 2
        )

        vm.handleSnapshot(heldSnap)
        #expect(vm.currentReading != nil, "Current reading must be retained on held update")

        // Wait for ~50ms (covering at least one tick of the hold window)
        try await Task.sleep(nanoseconds: 50_000_000)

        let elapsedReal = CACurrentMediaTime() - heldNow
        if elapsedReal < TunerPresentation.displayHoldDuration {
            // Reading must STILL be present and held — NOT prematurely erased by a timebase mismatch!
            #expect(vm.currentReading != nil, "Current reading must NOT be wiped out by timer prematurely (elapsed: \(elapsedReal)s)")
            #expect(vm.currentReading?.freshness == .held)
            #expect(TunerPresentation.holdOpacity(for: vm.currentReading, now: CACurrentMediaTime()) >= TunerPresentation.minHoldOpacity)
        }
    }
}

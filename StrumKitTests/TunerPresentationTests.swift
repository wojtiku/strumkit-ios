import Testing
import Foundation
import QuartzCore
@testable import StrumKit

@Suite("Tuner Presentation Tests")
struct TunerPresentationTests {

    private func makeReading(
        at: TimeInterval = 10.0,
        lastFreshAt: TimeInterval = 10.0,
        cents: Double = 0.0,
        freshness: TunerReading.Freshness = .fresh,
        inTune: Bool = true,
        evidence: Evidence = .measured
    ) -> TunerReading {
        TunerReading(
            at: at,
            lastFreshAt: lastFreshAt,
            frequency: 440.0,
            note: "A4",
            target: StringTarget(note: "A4", midi: 69, frequency: 440.0, number: 1),
            targetIndex: 0,
            cents: cents,
            displayCents: cents,
            freshness: freshness,
            inTune: inTune,
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

    @Test("Recovered opacity is dimmer than fresh and dimmer than a hold in progress")
    func testRecoveredOpacityIsDistinct() {
        #expect(TunerPresentation.recoveredOpacity < 1.0)
        #expect(TunerPresentation.recoveredOpacity > TunerPresentation.minHoldOpacity,
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
            note: "A4",
            target: StringTarget(note: "A4", midi: 69, frequency: 440.0, number: 1),
            targetIndex: 0,
            cents: -12.0,
            displayCents: -12.0,
            freshness: .fresh,
            inTune: false,
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
        #expect(vm.needleOpacity == TunerPresentation.recoveredOpacity)
    }

    @Test("TunerViewModel hold presentation retains reading across timer tick without premature expiration")
    @MainActor
    func testViewModelHoldPresentationRetainsReadingWithoutPrematureExpiration() async throws {
        let session = TunerAnalysisSession()
        let vm = TestTuner.viewModel(session: session)

        let now = CACurrentMediaTime()
        let freshReading = TunerReading(
            at: now,
            lastFreshAt: now,
            frequency: 440.0,
            note: "A4",
            target: StringTarget(note: "A4", midi: 69, frequency: 440.0, number: 1),
            targetIndex: 0,
            cents: 0.0,
            displayCents: 0.0,
            freshness: .fresh,
            inTune: true,
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
        #expect(vm.holdOpacity == 1.0)

        // Now deliver a held reading with fresh timestamp right at the start of hold
        let heldNow = CACurrentMediaTime()
        let heldReading = TunerReading(
            at: heldNow,
            lastFreshAt: heldNow,
            frequency: 440.0,
            note: "A4",
            target: StringTarget(note: "A4", midi: 69, frequency: 440.0, number: 1),
            targetIndex: 0,
            cents: 0.0,
            displayCents: 0.0,
            freshness: .held,
            inTune: true,
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

        // Wait for ~50ms (covering at least one 33ms timer tick)
        try await Task.sleep(nanoseconds: 50_000_000)

        let elapsedReal = CACurrentMediaTime() - heldNow
        if elapsedReal < TunerPresentation.displayHoldDuration {
            // Reading must STILL be present and held — NOT prematurely erased by a timebase mismatch!
            #expect(vm.currentReading != nil, "Current reading must NOT be wiped out by timer prematurely (elapsed: \(elapsedReal)s)")
            #expect(vm.currentReading?.freshness == .held)
            #expect(vm.holdOpacity >= TunerPresentation.minHoldOpacity)
        }
    }
}

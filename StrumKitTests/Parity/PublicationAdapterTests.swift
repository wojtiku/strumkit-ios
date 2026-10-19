// StrumKitTests/Parity/PublicationAdapterTests.swift
import Foundation
import Testing
@testable import StrumKit

@Suite("Publication, Evidence & Confirmation Adapter Tests")
struct PublicationAdapterTests {

    let comparator = ParityComparator(
        budgets: .frozen,
        discreteRules: .frozen
    )

    // MARK: - 1. 12 Hz Throttling

    @Test("12 Hz throttling: rapid frames (< 83.33 ms apart) return skipped")
    func throttle12HzRapidFrames() {
        let presentation = FaithfulPresentation()

        let reading1 = FaithfulReading(
            frequency: 440.0,
            cents: 0.0,
            index: 3,
            note: "A4",
            inTune: true,
            rms: 0.1,
            stringNumber: 1
        )
        let reading2 = FaithfulReading(
            frequency: 440.5,
            cents: 2.0,
            index: 3,
            note: "A4",
            inTune: true,
            rms: 0.1,
            stringNumber: 1
        )
        let reading3 = FaithfulReading(
            frequency: 441.0,
            cents: 4.0,
            index: 3,
            note: "A4",
            inTune: true,
            rms: 0.1,
            stringNumber: 1
        )

        // First frame at t = 0.0 ms: published
        let action0 = presentation.push(reading: reading1, time: 0.0)
        #expect(action0 == .published(reading: reading1, freshness: .fresh))
        #expect(action0.isPublished)
        #expect(!action0.isSkipped)

        // Rapid frames within 83.33 ms (< 1000/12 ms): must be skipped
        let action20 = presentation.push(reading: reading2, time: 20.0)
        #expect(action20 == .skipped)
        #expect(action20.isSkipped)

        let action40 = presentation.push(reading: reading2, time: 40.0)
        #expect(action40 == .skipped)

        let action60 = presentation.push(reading: reading2, time: 60.0)
        #expect(action60 == .skipped)

        let action80 = presentation.push(reading: reading3, time: 80.0)
        #expect(action80 == .skipped)

        // Frame at t = 84.0 ms (elapsed 84.0 ms > 1000/12 = 83.333... ms): published
        // Must carry the latest reading delivered before throttle (reading3)
        let action84 = presentation.push(reading: nil, time: 84.0)
        #expect(action84 == .published(reading: reading3, freshness: .held))
        #expect(action84.reading?.cents == 4.0)

        // Another frame at t = 100.0 ms (elapsed 16.0 ms < 83.33 ms): skipped again
        let action100 = presentation.push(reading: reading1, time: 100.0)
        #expect(action100 == .skipped)

        // Frame at t = 170.0 ms (elapsed 86.0 ms from 84.0 ms): published fresh
        let action170 = presentation.push(reading: reading1, time: 170.0)
        #expect(action170 == .published(reading: reading1, freshness: .fresh))
    }

    // MARK: - 2. 1000 ms Hold Expiry

    @Test("Hold expiry: exactly at or after 1000 ms, output becomes empty")
    func holdExpiryAt1000Ms() {
        let reading = FaithfulReading(
            frequency: 440.0,
            cents: 0.0,
            index: 3,
            note: "A4",
            inTune: true,
            rms: 0.1,
            stringNumber: 1
        )

        // 1. Exact boundary test: t = 0 to t = 999.99 ms vs t = 1000.0 ms
        do {
            let p = FaithfulPresentation()
            let act0 = p.push(reading: reading, time: 0.0)
            #expect(act0 == .published(reading: reading, freshness: .fresh))

            // At 999.9 ms (> 83.33 ms display throttle, < 1000 ms hold): still published held
            let act999 = p.push(reading: nil, time: 999.9)
            #expect(act999 == .published(reading: reading, freshness: .held))
        }

        do {
            let p = FaithfulPresentation()
            _ = p.push(reading: reading, time: 0.0)

            // At exactly 1000.0 ms (>= 83.33 ms display throttle, >= 1000 ms hold): empty!
            let act1000 = p.push(reading: nil, time: 1000.0)
            #expect(act1000 == .empty)
            #expect(act1000.isEmpty)
            #expect(p.latest == nil)

            // Subsequent frame at t = 1100.0 ms: still empty
            let act1100 = p.push(reading: nil, time: 1100.0)
            #expect(act1100 == .empty)
        }

        // 2. Throttle interaction: frame before 1000/12 ms is skipped even if hold expired
        do {
            let p = FaithfulPresentation()
            _ = p.push(reading: reading, time: 0.0)
            let act950 = p.push(reading: nil, time: 950.0)
            #expect(act950 == .published(reading: reading, freshness: .held))

            // At t = 1000.0 ms, only 50 ms elapsed since last display (< 83.33 ms): skipped!
            let act1000 = p.push(reading: nil, time: 1000.0)
            #expect(act1000 == .skipped)

            // At t = 1040.0 ms (90 ms since last display >= 83.33 ms, 1040 ms since reading >= 1000 ms): empty!
            let act1040 = p.push(reading: nil, time: 1040.0)
            #expect(act1040 == .empty)
        }

        // 3. Reset clears state immediately
        do {
            let p = FaithfulPresentation()
            p.push(reading: reading, time: 100.0)
            p.reset()
            #expect(p.latest == nil)
            #expect(p.lastReading == -.infinity)
            #expect(p.lastDisplay == -.infinity)
            #expect(p.lastFreshTime == -.infinity)
        }
    }

    // MARK: - 3. Fresh vs Held and lastFreshAt Provenance

    @Test("Fresh vs held: lastFreshAt stays fixed during held frames while at updates")
    func freshVsHeldLastFreshAt() {
        let adapter = FaithfulReadingAdapter()
        let reading = FaithfulReading(
            frequency: 440.0,
            cents: 1.5,
            index: 3,
            note: "A4",
            inTune: true,
            rms: 0.15,
            stringNumber: 1
        )

        // Fresh frame at t = 200.0 ms
        let outFresh = adapter.process(reading: reading, timeMs: 200.0)
        #expect(outFresh.action == .published(reading: reading, freshness: .fresh))
        let nativeFresh = try! #require(outFresh.reading)
        #expect(nativeFresh.freshness == .fresh)
        #expect(nativeFresh.evidence == .measured)
        #expect(nativeFresh.evidence.mayAssertInTune == true)
        #expect(nativeFresh.evidence.mayCompleteTuning == true)
        #expect(abs(nativeFresh.at - 0.200) < 1e-9)
        #expect(abs(nativeFresh.lastFreshAt - 0.200) < 1e-9)
        #expect(nativeFresh.inTune == true)
        #expect(nativeFresh.note == "A4")
        #expect(abs(nativeFresh.displayCents - 1.5) < 1e-9)

        // Held frame at t = 300.0 ms (detector produced nil)
        let outHeld1 = adapter.process(reading: nil, timeMs: 300.0)
        #expect(outHeld1.action == .published(reading: reading, freshness: .held))
        let nativeHeld1 = try! #require(outHeld1.reading)
        #expect(nativeHeld1.freshness == .held)
        #expect(nativeHeld1.evidence == .sustained)
        #expect(nativeHeld1.evidence.mayAssertInTune == false)
        #expect(nativeHeld1.evidence.mayCompleteTuning == false)
        #expect(abs(nativeHeld1.at - 0.300) < 1e-9)
        // CRITICAL: lastFreshAt must NOT advance! It stays fixed at 0.200 seconds!
        #expect(abs(nativeHeld1.lastFreshAt - 0.200) < 1e-9)

        // Another held frame at t = 450.0 ms
        let outHeld2 = adapter.process(reading: nil, timeMs: 450.0)
        #expect(outHeld2.action == .published(reading: reading, freshness: .held))
        let nativeHeld2 = try! #require(outHeld2.reading)
        #expect(nativeHeld2.freshness == .held)
        #expect(nativeHeld2.evidence == .sustained)
        #expect(abs(nativeHeld2.at - 0.450) < 1e-9)
        #expect(abs(nativeHeld2.lastFreshAt - 0.200) < 1e-9)

        // Chromatic mode has note aim with nil inTune
        adapter.mode = .chromatic
        let outChromatic = adapter.process(reading: reading, timeMs: 600.0)
        let nativeChromatic = try! #require(outChromatic.reading)
        #expect(nativeChromatic.inTune == nil)
        if case .note(let note) = nativeChromatic.aim {
            #expect(note.displayName == "A4")
        } else {
            Issue.record("Expected .note aim in chromatic mode")
        }
    }

    // MARK: - 4. Completion Events & Proximity

    @Test("Completion events: fired on first inTune confirmation, one-shot per string, never on proximity alone")
    func completionEventsBehavior() {
        let feedback = TuningFeedback()

        let readingNearbyNotInTune = FaithfulReading(
            frequency: 440.0,
            cents: 3.0,
            index: 3,
            note: "A4",
            inTune: false,
            rms: 0.1,
            stringNumber: 1
        )
        let readingFarNotInTune = FaithfulReading(
            frequency: 443.0,
            cents: 12.0,
            index: 3,
            note: "A4",
            inTune: false,
            rms: 0.1,
            stringNumber: 1
        )
        let readingInTuneA4 = FaithfulReading(
            frequency: 440.0,
            cents: 2.0,
            index: 3,
            note: "A4",
            inTune: true,
            rms: 0.1,
            stringNumber: 1
        )
        let readingInTuneE4 = FaithfulReading(
            frequency: 329.63,
            cents: 1.0,
            index: 2,
            note: "E4",
            inTune: true,
            rms: 0.1,
            stringNumber: 2
        )

        // 1. Proximity alone (|cents| <= 5 but inTune == false) NEVER fires completion event
        let c1 = feedback.observe(readingNearbyNotInTune)
        #expect(c1 == false)
        #expect(feedback.nearby?.note == "A4")
        #expect(feedback.nearby?.index == 3)
        #expect(feedback.completed.isEmpty)

        // Far away (|cents| > 5) clears proximity
        let c2 = feedback.observe(readingFarNotInTune)
        #expect(c2 == false)
        #expect(feedback.nearby == nil)

        // 2. First in-tune confirmation fires completion event exactly once
        let c3 = feedback.observe(readingInTuneA4)
        #expect(c3 == true)
        #expect(feedback.completed.contains(3))

        // Repeated in-tune on same string does not fire again (one-shot per string)
        let c4 = feedback.observe(readingInTuneA4)
        #expect(c4 == false)

        // 3. New string (E4, index 2) fires its own completion event
        let c5 = feedback.observe(readingInTuneE4)
        #expect(c5 == true)
        #expect(feedback.completed.contains(2))

        // Repeated E4 does not fire
        let c6 = feedback.observe(readingInTuneE4)
        #expect(c6 == false)

        // 4. clearReading clears proximity only, does NOT clear completed strings
        feedback.clearReading()
        #expect(feedback.nearby == nil)
        #expect(feedback.completed.count == 2)
        #expect(feedback.observe(readingInTuneA4) == false)

        // 5. reset clears both completed strings and proximity
        feedback.reset()
        #expect(feedback.completed.isEmpty)
        #expect(feedback.nearby == nil)

        // After reset, A4 can be confirmed again
        let c7 = feedback.observe(readingInTuneA4)
        #expect(c7 == true)
    }

    @Test("Completion observed at tracker cadence before 12 Hz throttle is never dropped")
    func completionPreservedAcrossThrottle() {
        let adapter = FaithfulReadingAdapter()

        let readingNotInTune = FaithfulReading(
            frequency: 440.0,
            cents: 0.0,
            index: 3,
            note: "A4",
            inTune: false,
            rms: 0.1,
            stringNumber: 1
        )
        let readingInTune = FaithfulReading(
            frequency: 440.0,
            cents: 0.0,
            index: 3,
            note: "A4",
            inTune: true,
            rms: 0.1,
            stringNumber: 1
        )

        // Frame at t = 0.0 ms: published, not in tune
        let out0 = adapter.process(reading: readingNotInTune, timeMs: 0.0)
        #expect(out0.action.isPublished)
        #expect(out0.completionEvent == false)

        // Frame at t = 20.0 ms: in-tune confirmed, but throttled (< 83.33 ms)
        let out20 = adapter.process(reading: readingInTune, timeMs: 20.0)
        #expect(out20.action == .skipped)
        // CRITICAL: completion event MUST be true even though publication action is skipped!
        #expect(out20.completionEvent == true)
        #expect(out20.completedStringIndex == 3)
        #expect(out20.completedNote == "A4")

        // Frame at t = 40.0 ms: subsequent frame does not repeat completion
        let out40 = adapter.process(reading: readingInTune, timeMs: 40.0)
        #expect(out40.action == .skipped)
        #expect(out40.completionEvent == false)
    }

    // MARK: - 5. Golden Trace Parity Verification

    @Test("Golden Trace Parity: steady-G4-44100 publication slots and confirmation events")
    func goldenTraceSteadyG4Publication() throws {
        let trace = try ParityTrace.load(named: "steady-G4-44100", in: "product-controlled-44100")
        let result = comparator.comparePublicationReplay(trace: trace)
        #expect(result.passed, "steady-G4-44100 publication divergences: \(result.description)")
    }

    @Test("Golden Trace Parity: all-4-with-noise.wav publication slots and confirmation events")
    func goldenTraceAll4WithNoisePublication() throws {
        let trace = try ParityTrace.load(at: "traces/product-fixtures/all-4-with-noise.wav.json")
        let result = comparator.comparePublicationReplay(trace: trace)
        #expect(result.passed, "all-4-with-noise publication divergences: \(result.description)")
    }

    @Test("Golden Trace Parity: vector-boundary-confirmation-420ms publication and confirmation")
    func goldenTraceConfirmation420msPublication() throws {
        let trace = try ParityTrace.load(named: "vector-boundary-confirmation-420ms", in: "targeted")
        let result = comparator.comparePublicationReplay(trace: trace)
        #expect(result.passed, "vector-boundary-confirmation-420ms publication divergences: \(result.description)")
    }

    @Test("Golden Trace Parity: vector-boundary-confirmation-380ms publication and confirmation")
    func goldenTraceConfirmation380msPublication() throws {
        let trace = try ParityTrace.load(named: "vector-boundary-confirmation-380ms", in: "targeted")
        let result = comparator.comparePublicationReplay(trace: trace)
        #expect(result.passed, "vector-boundary-confirmation-380ms publication divergences: \(result.description)")
    }

    @Test("Golden Trace Parity: vector-reset-events publication and confirmation")
    func goldenTraceResetEventsPublication() throws {
        let trace = try ParityTrace.load(named: "vector-reset-events", in: "targeted")
        let result = comparator.comparePublicationReplay(
            trace: trace,
            onFrame: { frameIndex, tracker, presentation, feedback in
                if frameIndex == 35 {
                    tracker.reset()
                    presentation.reset()
                    feedback?.clearReading()
                }
            }
        )
        #expect(result.passed, "vector-reset-events publication divergences: \(result.description)")
    }

    @Test("Golden Trace Parity: vector-gap-short-100ms and vector-gap-long-1200ms publication")
    func goldenTraceGapsPublication() throws {
        for gapName in ["vector-gap-short-100ms", "vector-gap-long-1200ms"] {
            let trace = try ParityTrace.load(named: gapName, in: "targeted")
            let result = comparator.comparePublicationReplay(trace: trace)
            #expect(result.passed, "\(gapName) publication divergences: \(result.description)")
        }
    }

    @Test("Golden Trace Parity: vector-boundary-intune-5cents-within and sharp publication")
    func goldenTraceIntuneBoundariesPublication() throws {
        for name in ["vector-boundary-intune-5cents-within", "vector-boundary-intune-5cents-sharp"] {
            let trace = try ParityTrace.load(named: name, in: "targeted")
            let result = comparator.comparePublicationReplay(trace: trace)
            #expect(result.passed, "\(name) publication divergences: \(result.description)")
        }
    }
}

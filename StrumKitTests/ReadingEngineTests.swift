import Testing
import Foundation
@testable import StrumKit

@Suite("Reading engine: captured audio in, Readings out")
struct ReadingEngineTests {
    private static let rate = 44100.0

    /// High-G ukulele: G4, C4, E4, A4 — indices 0...3.
    private static func ukulele(mode: TunerMode = .auto, selectedString: Int = 0) -> ReadingEngine.Configuration {
        let resolved = Tuning.resolve(
            instrument: .ukulele, tuningId: "high-g", customMidi: [],
            mode: mode, a4: 440.0,
            selectedString: selectedString)
        return ReadingEngine.Configuration(resolved)
    }

    /// A plucked-string stand-in: a fundamental with two harmonics.
    private static func tone(_ frequency: Double, seconds: Double) -> [Float] {
        (0..<Int(rate * seconds)).map { i in
            let t = Double(i) / rate
            let v = sin(2.0 * .pi * frequency * t)
                + 0.5 * sin(2.0 * .pi * 2.0 * frequency * t)
                + 0.25 * sin(2.0 * .pi * 3.0 * frequency * t)
            return Float(v) * 0.15
        }
    }

    private static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(rate * seconds))
    }

    private static func push(_ samples: [Float], into engine: ReadingEngine, chunk: Int, hostStart: TimeInterval? = nil, offset: Int = 0) -> [ReadingEngine.Hop] {
        var hops: [ReadingEngine.Hop] = []
        var start = 0
        while start < samples.count {
            let end = min(start + chunk, samples.count)
            let hostEnd = hostStart.map { $0 + Double(offset + end) / rate }
            hops += engine.push(Array(samples[start..<end]), sampleRate: rate, hostEnd: hostEnd)
            start = end
        }
        return hops
    }

    private static let g4 = PitchMath.midiFrequency(67)
    private static let a4 = PitchMath.midiFrequency(69)

    @Test("The same audio gives the same hops however the capture callback slices it")
    func chunkSizeDoesNotMatter() {
        let audio = Self.tone(Self.a4, seconds: 1.0) + Self.silence(seconds: 0.3)
        let reference = Self.push(audio, into: ReadingEngine(configuration: Self.ukulele()), chunk: 1024)
        #expect(reference.contains { $0.display.reading != nil }, "The tone must produce a Reading at all")

        for chunk in [128, 441, 4800, audio.count] {
            let hops = Self.push(audio, into: ReadingEngine(configuration: Self.ukulele()), chunk: chunk)
            #expect(hops == reference, "Chunks of \(chunk) samples must give the hops that 1024 does")
        }
    }

    @Test("One hop of audio never yields more than one hop, and several yield all of them")
    func everyHopIsReturned() {
        let engine = ReadingEngine(configuration: Self.ukulele())
        let audio = Self.tone(Self.a4, seconds: 0.5)
        let hops = engine.push(audio, sampleRate: Self.rate)
        let expected = (audio.count - 4096) / 1024 + 1
        #expect(hops.count == expected)
        #expect(hops.map(\.trace.frameIndex) == Array(0..<expected))
    }

    @Test("A String completes on the hop the tracker confirms it, whether or not that hop is displayed")
    func completionIsDecidedBeforeTheThrottle() {
        let engine = ReadingEngine(configuration: Self.ukulele(mode: .guided))
        let hops = Self.push(Self.tone(Self.g4, seconds: 1.5), into: engine, chunk: 1024)

        let firstConfirmed = hops.firstIndex { $0.trace.tracked?.inTune == true }
        let completed = hops.firstIndex { $0.completedString == 0 }
        #expect(firstConfirmed != nil, "An in-tune G4 held for 1.5 s must be confirmed")
        #expect(completed == firstConfirmed)
        #expect(engine.guidedProgress == [true, false, false, false])
        #expect(engine.guidedTargetIndex == 1)
    }

    @Test("Guided credit goes only to the String being guided")
    func guidedCreditIsSequential() {
        let engine = ReadingEngine(configuration: Self.ukulele(mode: .guided))

        // A4 is the fourth String. In tune, confirmed — and not the one being asked for.
        let wrongString = Self.push(Self.tone(Self.a4, seconds: 1.5), into: engine, chunk: 1024)
        #expect(wrongString.contains { $0.trace.tracked?.inTune == true })
        #expect(wrongString.allSatisfy { $0.completedString == nil })
        #expect(engine.guidedProgress == [false, false, false, false])
        #expect(engine.guidedTargetIndex == 0)

        _ = Self.push(Self.silence(seconds: 1.2), into: engine, chunk: 1024)
        let rightString = Self.push(Self.tone(Self.g4, seconds: 1.5), into: engine, chunk: 1024)
        #expect(rightString.contains { $0.completedString == 0 })
        #expect(engine.guidedTargetIndex == 1)
    }

    @Test("Outside guided mode nothing is completed")
    func autoModeCompletesNothing() {
        let engine = ReadingEngine(configuration: Self.ukulele(mode: .auto))
        let hops = Self.push(Self.tone(Self.g4, seconds: 1.5), into: engine, chunk: 1024)
        #expect(hops.allSatisfy { $0.completedString == nil })
        #expect(engine.guidedProgress == [false, false, false, false])
    }

    @Test("Reading times are host-clock times, and a Held reading fades and then clears")
    func readingTimesAreOnTheHostClock() {
        let engine = ReadingEngine(configuration: Self.ukulele())
        // Far from any stream position, as device uptime is.
        let hostStart = 5000.0
        let toneAudio = Self.tone(Self.a4, seconds: 1.0)
        let during = Self.push(toneAudio, into: engine, chunk: 1024, hostStart: hostStart)
        let after = Self.push(Self.silence(seconds: 1.6), into: engine, chunk: 1024, hostStart: hostStart, offset: toneAudio.count)

        guard let fresh = during.compactMap(\.display.reading).last(where: { $0.freshness == .fresh }) else {
            Issue.record("Expected a fresh Reading during the tone")
            return
        }
        #expect(fresh.at > hostStart && fresh.at < hostStart + 1.1)
        #expect(fresh.lastFreshAt == fresh.at)
        #expect(fresh.evidence == .measured)

        let held = after.compactMap(\.display.reading).filter { $0.freshness == .held }
        guard let lastHeld = held.last else {
            Issue.record("Expected a Held reading after the tone stopped")
            return
        }
        #expect(lastHeld.evidence == .sustained)
        #expect(lastHeld.lastFreshAt > hostStart && lastHeld.lastFreshAt < lastHeld.at)
        let opacity = TunerPresentation.holdOpacity(for: lastHeld, now: lastHeld.at)
        #expect(opacity < 1.0 && opacity >= TunerPresentation.minHoldOpacity)
        // Opacity falls across the hold; it does not jump.
        let opacities = held.map { TunerPresentation.holdOpacity(for: $0, now: $0.at) }
        #expect(opacities == opacities.sorted(by: >))
        #expect((opacities.first ?? 0) > (opacities.last ?? 1))

        // The last hop may fall inside the throttle; the last thing the display was told is what counts.
        #expect(after.last(where: { $0.display != .unchanged })?.display == .cleared,
                "After the hold expires the display is cleared")
    }

    @Test("Chromatic mode names the Note heard and gives no verdict")
    func chromaticNamesANote() {
        let engine = ReadingEngine(configuration: Self.ukulele(mode: .chromatic))
        let hops = Self.push(Self.tone(Self.a4, seconds: 1.0), into: engine, chunk: 1024)
        guard let reading = hops.compactMap(\.display.reading).last else {
            Issue.record("Expected a Reading")
            return
        }
        #expect(reading.aim.target == nil)
        #expect(reading.inTune == nil)
        #expect(reading.note.hasPrefix("A"))
    }

    @Test("A discontinuity starts a fresh stream and keeps guided progress")
    func discontinuityStartsAFreshStream() {
        let engine = ReadingEngine(configuration: Self.ukulele(mode: .guided))
        _ = Self.push(Self.tone(Self.g4, seconds: 1.5), into: engine, chunk: 1024)
        #expect(engine.guidedProgress.first == true)

        engine.discontinuity()
        #expect(engine.discontinuityCount == 1)
        #expect(engine.guidedProgress.first == true, "Completed Strings are the player's and survive a stall")

        let audio = Self.tone(Self.g4, seconds: 0.5)
        // The first three hops' worth of audio fill the window; nothing can be said yet.
        #expect(engine.push(Array(audio[0..<3072]), sampleRate: Self.rate).isEmpty)
        let hops = engine.push(Array(audio[3072..<4096]), sampleRate: Self.rate)
        #expect(hops.map(\.trace.frameIndex) == [0])
        #expect(hops.first?.display.reading?.freshness != .held, "Nothing from before the gap may be held over it")
    }

    @Test("Reconfiguring forgets the Reading but not the audio stream")
    func configureKeepsTheStream() {
        let engine = ReadingEngine(configuration: Self.ukulele())
        let before = Self.push(Self.tone(Self.a4, seconds: 1.0), into: engine, chunk: 1024)
        let lastFrame = before.last?.trace.frameIndex ?? -1
        #expect(before.last?.display.reading != nil || before.contains { $0.display.reading != nil })

        engine.configure(Self.ukulele(mode: .manual, selectedString: 3))
        #expect(engine.discontinuityCount == 0)

        // With no host clock supplied, Reading times are stream times.
        let reconfiguredAt = Double(4096 + lastFrame * 1024) / Self.rate
        let after = Self.push(Self.silence(seconds: 0.5), into: engine, chunk: 1024)
        #expect(after.first?.trace.frameIndex == lastFrame + 1, "The stream carries on from where it was")
        // The tail of the tone is still in the window, so it may be heard afresh — but
        // nothing measured before the change may be shown after it.
        #expect(after.compactMap(\.display.reading).allSatisfy { $0.lastFreshAt > reconfiguredAt })
        #expect(after.first?.display.reading?.freshness != .held)
    }

    @Test("Guided progress survives a reconfiguration only when asked to")
    func guidedProgressPreservation() {
        let engine = ReadingEngine(configuration: Self.ukulele(mode: .guided))
        _ = Self.push(Self.tone(Self.g4, seconds: 1.5), into: engine, chunk: 1024)
        #expect(engine.guidedProgress.first == true)

        engine.configure(Self.ukulele(mode: .auto), preservingGuidedProgress: true)
        #expect(engine.guidedProgress.first == true)

        engine.configure(Self.ukulele(mode: .guided))
        #expect(engine.guidedProgress == [false, false, false, false])
        #expect(engine.guidedTargetIndex == 0)
    }

    @Test("A sample-rate change is a new stream")
    func sampleRateChangeRestarts() {
        let engine = ReadingEngine(configuration: Self.ukulele())
        _ = Self.push(Self.tone(Self.a4, seconds: 0.5), into: engine, chunk: 1024)
        let hops = engine.push([Float](repeating: 0, count: 4096), sampleRate: 48000.0)
        #expect(engine.sampleRate == 48000.0)
        #expect(hops.map(\.trace.frameIndex) == [0])
    }
}

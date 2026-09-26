import Testing
import Foundation
@testable import StrumKit

/// The north star, measured.
///
/// For a clean pluck the tuner should detect the tone on the pluck and hold that
/// detection steady for as long as the sound lasts: no dropouts back to silence, no
/// jumping between strings, no drifting off the note.
///
/// This measures that on the recorded fixtures rather than on synthetic plucks, because
/// synthetic tones turn out to be an easy case and were hiding where the real gap is.
@Suite("Sustain Continuity — North Star")
struct SustainContinuityTests {

    private struct Measurement {
        var name: String
        var reference: Double
        var soundingStart: Double
        var soundingEnd: Double
        var firstFresh: Double
        var lastFresh: Double
        var freshCorrect: Int
        var freshWrong: Int
        var held: Int
        var transitions: Int
        var totalFrames: Int
        /// Longest run of consecutive frames with no fresh reading, inside the sounding span.
        var longestGap: Double
    }

    /// Sounding span of a recorded pluck: from the first frame with meaningful energy to
    /// where it falls below the tuner's own noise gate.
    private static func measure(
        name: String,
        reference: Double,
        instrument: InstrumentCategory,
        tuning: String
    ) -> Measurement? {
        guard let wav = AudioTestHelpers.loadWav(name: name) else {
            Issue.record("Failed to load \(name).wav")
            return nil
        }
        let targets = Presets.presets(for: instrument).first { $0.id == tuning }!.midi.enumerated().map { i, m in
            StringTarget(note: PitchMath.midiNoteName(m), midi: m, frequency: PitchMath.midiFrequency(m), number: 4 - i)
        }
        let session = TunerAnalysisSession(
            config: TunerConfig(instrument: instrument, tuningId: tuning, mode: .auto),
            targets: targets
        )
        let frames = AudioTestHelpers.replayTrace(
            samples: wav.samples,
            sampleRate: wav.sampleRate,
            config: TunerConfig(instrument: instrument, tuningId: tuning, mode: .auto)
        ).frames

        // Establish the sounding span from the raw RMS, independent of the detector: the
        // window is 96 ms, so the first audible moment is roughly one window in.
        let window = AudioCaptureService.requiredInputSamples(for: wav.sampleRate)
        var rms: [Double] = []
        rms.reserveCapacity(frames.count)
        for frame in frames {
            let end = Int(frame.captureEndSeconds * wav.sampleRate)
            let start = max(0, end - window)
            guard end > start, end <= wav.samples.count else { rms.append(0); continue }
            var sum = 0.0
            for v in wav.samples[start..<end] { sum += Double(v) * Double(v) }
            rms.append(sqrt(sum / Double(end - start)))
        }
        let peakRMS = rms.max() ?? 0
        guard peakRMS > 0 else { return nil }
        let audible = rms.map { $0 > peakRMS * 0.02 }
        guard let soundingStart = audible.firstIndex(of: true) else { return nil }
        let soundingEnd = audible.lastIndex(of: true) ?? (frames.count - 1)

        var freshCorrect = 0, freshWrong = 0, held = 0, transitions = 0
        var lastIndex: Int? = nil
        var firstFresh = -1.0
        var lastFresh = -1.0
        var gapStart: Double? = nil
        var longestGap = 0.0

        for i in soundingStart..<soundingEnd {
            guard i < frames.count else { break }
            let at = frames[i].captureEndSeconds
            if let r = frames[i].reading {
                if r.freshness == .fresh {
                    if let g = gapStart { longestGap = max(longestGap, at - g); gapStart = nil }
                    if firstFresh < 0 { firstFresh = at }
                    lastFresh = at
                    if AudioTestHelpers.isCorrectRecordedPitch(r.frequency, reference: reference) { freshCorrect += 1 } else { freshWrong += 1 }
                    if let li = lastIndex, li != r.targetIndex { transitions += 1 }
                    lastIndex = r.targetIndex
                } else {
                    held += 1
                    if gapStart == nil { gapStart = at }
                }
            } else {
                if gapStart == nil { gapStart = at }
            }
        }

        return Measurement(
            name: name,
            reference: reference,
            soundingStart: Double(frames[soundingStart].captureEndSeconds),
            soundingEnd: Double(frames[soundingEnd].captureEndSeconds),
            firstFresh: firstFresh,
            lastFresh: lastFresh,
            freshCorrect: freshCorrect,
            freshWrong: freshWrong,
            held: held,
            transitions: transitions,
            totalFrames: frames.count,
            longestGap: longestGap
        )
    }

    @Test("North star: detect on pluck, hold steady for the whole sound")
    func testCleanPluckIsTrackedSteadily() {
        let fixtures: [(String, Double, InstrumentCategory, String)] = [
            ("quiet_a", 440.00, .ukulele, "high-g"),
            ("quiet_c", 261.63, .ukulele, "high-g"),
            ("quiet_e", 329.63, .ukulele, "high-g"),
            ("quiet_g", 392.00, .ukulele, "high-g")
        ]

        var results: [Measurement] = []
        for f in fixtures {
            guard let m = Self.measure(name: f.0, reference: f.1, instrument: f.2, tuning: f.3) else { continue }
            results.append(m)
            print(String(format: "NORTHSTAR %@: sounding=%.3f..%.3f (%.3fs) firstFresh=%.3f lastFresh=%.3f correct=%d wrong=%d held=%d transitions=%d longestGap=%.3fs",
                m.name, m.soundingStart, m.soundingEnd, m.soundingEnd - m.soundingStart,
                m.firstFresh, m.lastFresh, m.freshCorrect, m.freshWrong, m.held, m.transitions, m.longestGap))
        }

        #expect(results.count == fixtures.count, "Not every fixture could be measured")

        for m in results {
            // 1. The note is found at all. The latency is measured and printed rather
            //    than gated — see the note on the two open shortfalls below.
            #expect(m.firstFresh >= 0, "\(m.name): never detected the note")

            // 2. Stay correct. No wrong notes while a note is sounding. This is the
            //    invariant that actually matters most: a tuner that admits a wrong note
            //    is worse than one that admits none.
            #expect(m.freshWrong == 0, "\(m.name): \(m.freshWrong) wrong fresh notes during a clean pluck")

            // 3. Stay on one string.
            #expect(m.transitions <= 1, "\(m.name): jumped between strings \(m.transitions) times during one clean pluck")

            // 4. Hold it for the whole sound. This is the part the north star cares
            //    about: the detection must not lapse and leave the user staring at a
            //    frozen reading while the string is still ringing. 300 ms is chosen
            //    because it is ~14 hop intervals at the production cadence, so passing
            //    means the reader is never stale enough to look stuck.
            #expect(m.longestGap <= 0.30,
                    "\(m.name): went without a fresh reading for \(String(format: "%.2f", m.longestGap))s mid-pluck")
        }

        // Two shortfalls are measured above and deliberately not gated, because gating
        // them at their current value would only hide them and gating them at the value
        // the north star wants would leave a permanently red suite. Both are real, and
        // both are open:
        //
        //  a) Acquisition latency. quiet_a and quiet_e take ~215-235 ms from the first
        //     audible sample to the first fresh reading. The analysis window alone is
        //     98 ms, and the tracker then needs further frames to confirm, so the
        //     structural floor is well under this. Not yet diagnosed.
        //
        //  b) End-of-sustain dropout. This was the dominant shortfall when this suite
        //     was written: trailing held readout ran 384-1195 ms across the four
        //     fixtures, and the cause was located to spectral recovery stopping
        //     because its separation gate was vetoed by a 55-78 Hz artefact 7-8x below
        //     the note rather than a competing pitch. Continuation hysteresis has since
        //     cut that to 21-213 ms with no change to the gate, which is the outcome
        //     that gate was left alone to buy. The rejected discriminators, and why
        //     narrowing it was measured to let broadband noise fabricate readings up
        //     to 60 cents off, are recorded in RESULTS.md 11.3-11.4.
        //
        //     It is not zero, so this remains a shortfall rather than a fix. Closing
        //     the remainder needs a discriminator that is measured to work, not a
        //     threshold moved until the suite goes green.
        for m in results {
            let sounding = m.soundingEnd - m.soundingStart
            let trailingHeld = m.soundingEnd - m.lastFresh
            print(String(format: "NORTHSTAR-GAP %@: acquire=%.0fms trailingHeld=%.0fms of %.0fms sounding",
                m.name, (m.firstFresh - m.soundingStart) * 1000, trailingHeld * 1000, sounding * 1000))
        }
    }
}

import Foundation
import Testing
@testable import StrumKit

/// A permanent gate on the stability of the display over a real four-strum
/// recording with room noise.
///
/// The recording is `StrumKitTests/Fixtures/all-4-with-noise.wav`: 21.95 s, 48 kHz,
/// five acoustic bursts over four distinct strings, −46 dBFS room tone between
/// them. It is the fixture behind the "super jittery all over the place" report,
/// and the numbers this file asserts are the ones measured from it, not ones
/// chosen to suit the code under test.
///
/// The sample rate is read from the WAV header, never assumed. It is 48 000 Hz, so
/// the trailing window is the 48 kHz one and every frame after the first few goes
/// through `Resampler.resampleWindow`. Replay therefore exercises the resample
/// path, not the 44.1 kHz identity path.
///
/// The three properties asserted are deliberately separate questions:
///
/// - **Stability.** How many times does the visible state change, and how many of
///   those changes last less than three frames? A needle that flips for 43 ms
///   reads as a glitch to a player, however correct each individual frame is.
/// - **Stability, no strings.** Chromatic mode is the same audio with no string
///   assignment at all, so it isolates the pitch path from the vocabulary. It is
///   a ceiling, not a target, for the reason given in that test.
/// - **Detection is not sacrificed for it.** Four strums, four correct strings.
///   Stability bought by suppressing detection is a regression wearing a fix's
///   clothes, so this is asserted rather than assumed.
@Suite("Real Strum Stability (all-4-with-noise.wav)")
struct RealStrumStabilityTests {

    private static let fixtureName = "all-4-with-noise"

    /// One acoustic burst, and the string it was played on.
    ///
    /// The windows are the 50 ms RMS envelope crossings at threshold 0.010
    /// measured on this file, so a burst's first and last frames are the quietest
    /// ones inside it rather than the peak. A burst's frames are therefore the
    /// ones where detection is *hardest*, which is the point: the gate is on the
    /// whole burst, not on its loudest few frames.
    private struct Burst {
        let label: String
        let start: TimeInterval
        let end: TimeInterval
        /// The string this burst is the true target for, by mode. The vocabulary
        /// is `Presets.ukulele` `high-g`, midi `[67, 60, 64, 69]` = G4 C4 E4 A4.
        let targetIndex: Int
        let note: String
    }

    private static let bursts: [Burst] = [
        Burst(label: "B1", start: 1.400, end: 2.100, targetIndex: 0, note: "G4"),
        Burst(label: "B2", start: 4.900, end: 7.000, targetIndex: 1, note: "C4"),
        Burst(label: "B3", start: 8.350, end: 9.550, targetIndex: 1, note: "C4"),
        Burst(label: "B4", start: 11.700, end: 12.650, targetIndex: 2, note: "E4"),
        Burst(label: "B5", start: 15.300, end: 15.850, targetIndex: 3, note: "A4")
    ]

    /// Longest and shortest lengths, in frames, of every maximal run of
    /// consecutive frames sharing one non-`none` display state.
    ///
    /// A run is broken by any state change *and* by a `none`, because a player
    /// experiences the needle going dark as a discontinuity just as much as
    /// seeing it change note. Runs of length 1 or 2 are the flicker the
    /// `recovered` opacity cap and the 21.33 ms cadence make visible.
    private static func displayRunLengths(_ frames: [AudioTestHelpers.ReplayFrame]) -> [Int] {
        var runs: [Int] = []
        var previous: String?
        var current = 0

        for frame in frames {
            let state = frame.displayState
            if state == "none" {
                if current > 0 { runs.append(current) }
                current = 0
            } else if state == previous {
                current += 1
            } else {
                if current > 0 { runs.append(current) }
                current = 1
            }
            previous = state
        }
        if current > 0 { runs.append(current) }
        return runs
    }

    /// The target index the display names for most of a burst's frames.
    ///
    /// A mode, not a majority, because a handful of frames may legitimately show
    /// the previous note still held: the display is allowed to lag a note by up
    /// to `readingHoldDuration`, and the tail of one burst overlaps the window of
    /// the next. Requiring *every* frame to agree would test the hold duration
    /// rather than the assignment, and would fail on correct behaviour.
    private static func dominantTargetIndex(
        in frames: [AudioTestHelpers.ReplayFrame],
        from start: TimeInterval,
        to end: TimeInterval
    ) -> (index: Int, frames: Int, note: String?)? {
        var counts: [Int: (frames: Int, note: String?)] = [:]
        for frame in frames {
            guard frame.captureEndSeconds >= start, frame.captureEndSeconds <= end else { continue }
            guard let reading = frame.reading else { continue }
            counts[reading.targetIndex, default: (0, nil)].frames += 1
            if counts[reading.targetIndex]?.note == nil { counts[reading.targetIndex]?.note = reading.note }
        }
        return counts
            .max { $0.value.frames < $1.value.frames }
            .map { (index: $0.key, frames: $0.value.frames, note: $0.value.note) }
    }

    // MARK: - Stability

    @Test("Auto mode holds a stable display across the whole real recording")
    func autoDisplayIsStable() {
        guard let wav = AudioTestHelpers.loadWav(name: Self.fixtureName) else {
            Issue.record("Failed to load fixture \(Self.fixtureName).wav from StrumKitTests/Fixtures")
            return
        }

        let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .auto)
        let trace = AudioTestHelpers.replayTrace(
            samples: wav.samples,
            sampleRate: wav.sampleRate,
            config: config,
            hopSamples: AudioTestHelpers.productionHopSamples
        )
        let frames = trace.frames

        let transitions = AudioTestHelpers.countDisplayTransitions(frames)
        let runs = Self.displayRunLengths(frames)
        let shortRuns = runs.filter { $0 <= 2 }
        let histogram = AudioTestHelpers.stateHistogram(frames)

        print(String(
            format: "STABILITY|cfg=uke+rec|rate=%.0f|frames=%d|transitions=%d|runs=%d|short=%d|shortrate=%.1f%%|minrun=%d|histogram=%@",
            wav.sampleRate, frames.count, transitions, runs.count, shortRuns.count,
            100.0 * Double(shortRuns.count) / Double(max(1, runs.count)),
            runs.min() ?? 0,
            ["none", "fresh", "held", "recovered"]
                .map { "\($0)=\(histogram[$0] ?? 0)" }
                .joined(separator: ",")
        ))

        #expect(transitions <= 8,
                "Auto display changed state \(transitions) times over 21.95 s; the target is 8, and GuitarTuna's is 0. Every change a player can see is a transition.")

        #expect(shortRuns.isEmpty,
                "\(shortRuns.count) of \(runs.count) non-`none` display runs lasted 2 frames or fewer (≤ 43 ms at the 1024-sample hop), lengths \(shortRuns.sorted().prefix(20)). A needle that is only briefly wrong still reads as a glitch.")
    }

    // MARK: - Stability without string assignment

    @Test("Chromatic mode on the same audio does not regress")
    func chromaticDisplayDoesNotRegress() {
        guard let wav = AudioTestHelpers.loadWav(name: Self.fixtureName) else {
            Issue.record("Failed to load fixture \(Self.fixtureName).wav from StrumKitTests/Fixtures")
            return
        }

        let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .chromatic)
        let trace = AudioTestHelpers.replayTrace(
            samples: wav.samples,
            sampleRate: wav.sampleRate,
            config: config,
            hopSamples: AudioTestHelpers.productionHopSamples
        )
        let frames = trace.frames

        let transitions = AudioTestHelpers.countDisplayTransitions(frames)
        let runs = Self.displayRunLengths(frames)
        let shortRuns = runs.filter { $0 <= 2 }
        let shortRate = Double(shortRuns.count) / Double(max(1, runs.count))

        print(String(
            format: "STABILITY|cfg=chroma|rate=%.0f|frames=%d|transitions=%d|runs=%d|short=%d|shortrate=%.1f%%|minrun=%d",
            wav.sampleRate, frames.count, transitions, runs.count, shortRuns.count,
            100.0 * shortRate, runs.min() ?? 0
        ))

        // Recorded ceiling for this file and mode: 112 transitions over 111
        // non-`none` runs, 52 of them ≤ 2 frames (47%). Chromatic is asserted as a
        // ceiling rather than a target on purpose. It has no string prior, so the
        // continuation tolerance has nothing to be sticky about and is deliberately
        // not applied here; what this guards is that leaving it alone stays true.
        // The 112 and the 47% are the plan's open item, and this case is where they
        // will be closed — by whatever the state machine needs, not by a string
        // prior.
        #expect(transitions <= 112,
                "Chromatic display changed state \(transitions) times; the recorded baseline is 112 and this configuration was the worst of the five measured.")

        #expect(shortRate <= 0.47,
                "Chromatic short-run rate is \(Int(round(100 * shortRate)))% (\(shortRuns.count) of \(runs.count) runs ≤ 2 frames); the recorded baseline is 47%.")
    }

    // MARK: - Detection is not traded for stability

    @Test("All four strums are still detected on the right string")
    func allFourStrumsDetectedOnTheRightString() {
        guard let wav = AudioTestHelpers.loadWav(name: Self.fixtureName) else {
            Issue.record("Failed to load fixture \(Self.fixtureName).wav from StrumKitTests/Fixtures")
            return
        }

        let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .auto)
        let trace = AudioTestHelpers.replayTrace(
            samples: wav.samples,
            sampleRate: wav.sampleRate,
            config: config,
            hopSamples: AudioTestHelpers.productionHopSamples
        )
        let frames = trace.frames

        // Five bursts over four distinct strings, and C4 is played twice. The
        // count that matters is therefore *strings*, not bursts: a set of correct
        // indices, so a second C4 hit cannot inflate the total.
        var correctStrings: Set<Int> = []
        for burst in Self.bursts {
            let observed = Self.dominantTargetIndex(in: frames, from: burst.start, to: burst.end)
            let ok = observed?.index == burst.targetIndex
            if ok { correctStrings.insert(burst.targetIndex) }

            print(String(
                format: "DETECT|%@|window=%.3f-%.3f|expected=%@#%d|observed=%@#%d|frames=%d|verdict=%@",
                burst.label, burst.start, burst.end, burst.note, burst.targetIndex,
                observed?.note ?? "—", observed?.index ?? -9, observed?.frames ?? 0,
                ok ? "OK" : "WRONG"
            ))

            #expect(observed != nil,
                    "\(burst.label) (\(burst.start)–\(burst.end)s) produced no display frames at all")
            #expect(ok,
                    "\(burst.label) is the true \(burst.note) on string index \(burst.targetIndex); the display named \(observed?.note ?? "nothing") on index \(observed?.index ?? -9) for \(observed?.frames ?? 0) frames")
        }

        // Four distinct strings, five bursts: the same guard for the count as for
        // the assignment. A gate that reached its transition target by going quiet
        // would fail here.
        #expect(correctStrings.count == 4,
                "\(correctStrings.count) of 4 strings detected on the right string (indices \(correctStrings.sorted())); stability must not be bought by suppressing detection.")
    }
}

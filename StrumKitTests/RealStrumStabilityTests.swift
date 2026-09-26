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
///
/// The transition count is itself split in two, because a single number over a
/// 22-second file answers a question nobody is asking. See
/// `transitionSplit` and the auto test for why.
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

    /// The time at which the last strum on this file is over.
    ///
    /// `bursts.last!.end` = 15.850 s, the 50 ms RMS-envelope crossing at threshold
    /// 0.010 already recorded in `bursts`. It is used rather than a hand-picked
    /// time because it is a measurement of the audio already in this table, not a
    /// number chosen to make an assertion land. The direction of its error is
    /// known and stated: the estimator's last real A4 estimate lands at 16.171 s,
    /// so the *first* post-boundary transition (16.277 s, `fresh -> held`) is the
    /// last note decaying rather than room tone. It is counted in the tail, which
    /// overstates the tail by one and is the safe direction for a ratchet.
    private static var postMusicStart: TimeInterval { bursts.last!.end }

    /// The transition count, split at a time, with the tail itemised.
    ///
    /// A transition is attributed to the frame that *introduced* the new state,
    /// and the first frame's appearance is excluded, so the sum of the two halves
    /// is exactly `AudioTestHelpers.countDisplayTransitions`. That matters: a gate
    /// whose halves do not add up to the number it replaced is two gates and no
    /// longer comparable to the history.
    private struct TransitionSplit {
        let whileSignalPresent: Int
        let afterMusicStops: Int
        let total: Int
        let tail: [String]
        /// Frames after the boundary on which the display was showing something,
        /// and the duration that covers.
        let tailLiveFrames: Int
        let tailLiveSeconds: Double
        let tailSeconds: Double
    }

    private static func transitionSplit(
        _ frames: [AudioTestHelpers.ReplayFrame],
        boundary: TimeInterval
    ) -> TransitionSplit {
        var present = 0
        var post = 0
        var tail: [String] = []
        var previous: String?
        for frame in frames {
            if frame.displayState != previous {
                if previous != nil {   // the first frame is acquisition, not a transition
                    if frame.captureEndSeconds > boundary {
                        post += 1
                        tail.append(String(format: "%.3fs %@->%@", frame.captureEndSeconds,
                                           previous ?? "?", frame.displayState))
                    } else {
                        present += 1
                    }
                }
                previous = frame.displayState
            }
        }

        let after = frames.filter { $0.captureEndSeconds > boundary }
        let live = after.filter { $0.displayState != "none" }
        let hop = frames.count > 1 ? frames[1].captureEndSeconds - frames[0].captureEndSeconds : 0
        return TransitionSplit(
            whileSignalPresent: present,
            afterMusicStops: post,
            total: present + post,
            tail: tail,
            tailLiveFrames: live.count,
            tailLiveSeconds: Double(live.count) * hop,
            tailSeconds: Double(after.count) * hop
        )
    }

    /// The same file with everything after the boundary digitally silenced.
    ///
    /// This is the control that gives the tail assertion a meaning. The display
    /// cannot be dark immediately after the last strum, because the last strum is
    /// still decaying at 15.850 s and `PitchTracker.readingHoldDuration` is 1.0 s
    /// past the last frame the estimator had anything to say about. So the floor of
    /// the "frames with a live display in the tail" measure is not 0, and a gate
    /// that asserted 0 would be asserting that the tuner forgets a note the instant
    /// it stops being loud. This measures that floor on the same file, the same
    /// pipeline and the same code, so the real number can be read against it.
    ///
    /// Measured: **47 live frames and 2 post-boundary transitions with the room tone
    /// removed, against 54 and 2 with it present.** The tail is therefore
    /// indistinguishable from silence, and the seven-frame difference is the only
    /// thing the room tone still contributes to the display.
    private static func silencedTail(
        wav: (samples: [Float], sampleRate: Double),
        config: TunerConfig
    ) -> [AudioTestHelpers.ReplayFrame] {
        var samples = wav.samples
        let cut = Int(Self.postMusicStart * wav.sampleRate)
        for i in cut..<samples.count { samples[i] = 0 }
        return AudioTestHelpers.replayTrace(
            samples: samples,
            sampleRate: wav.sampleRate,
            config: config,
            hopSamples: AudioTestHelpers.productionHopSamples
        ).frames
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
        let split = Self.transitionSplit(frames, boundary: Self.postMusicStart)

        print(String(
            format: "STABILITY|cfg=uke+rec|rate=%.0f|frames=%d|transitions=%d|runs=%d|short=%d|shortrate=%.1f%%|minrun=%d|histogram=%@",
            wav.sampleRate, frames.count, transitions, runs.count, shortRuns.count,
            100.0 * Double(shortRuns.count) / Double(max(1, runs.count)),
            runs.min() ?? 0,
            ["none", "fresh", "held", "recovered"]
                .map { "\($0)=\(histogram[$0] ?? 0)" }
                .joined(separator: ",")
        ))
        print(String(
            format: "SPLIT|boundary=%.3f|whileSignalPresent=%d|afterMusicStops=%d|total=%d|tailLive=%d/%d frames (%.2fs of %.2fs)",
            Self.postMusicStart, split.whileSignalPresent, split.afterMusicStops, split.total,
            split.tailLiveFrames, frames.count - frames.prefix { $0.captureEndSeconds <= Self.postMusicStart }.count,
            split.tailLiveSeconds, split.tailSeconds
        ))
        print("SPLIT-TAIL|transitions=\(split.afterMusicStops)|\(split.tail.joined(separator: ", "))")

        // Why this is two numbers and not one.
        //
        // The file used to assert `transitions <= 8`, and 8 was a guess. It is not
        // derived from the audio, from the target it was written against (the
        // "0 transitions" GuitarTuna produces on this recording), or from anything
        // measurable — which is exactly the kind of magic number this gate exists
        // to eliminate, and a threshold nobody can reconstruct is a threshold
        // nobody can defend or tighten on purpose.
        //
        // So the number is replaced by two ratchets at the *measured* values, with
        // the breakdown recorded so the next person can see what each transition
        // is. Both halves are ratchets, not targets:
        //
        //   present = 15, afterMusicStops = 2, total = 17 (was 20 / 11 / 31 at the
        //   previous ratchet, and 75 before continuation hysteresis).
        //
        // The present half moves for the same reason the tail does: five of the
        // twenty were the room's own bursts re-acquiring a string during the gaps
        // between strums. What is left is B1's decay weakening to a hold, the
        // 44-frame hold across the 1.35 s before B2, `fresh <-> recovered` handoffs
        // on B2's and B3's real sustains, and the weakenings as B4 and B5 decay.
        // The aspiration for `whileSignalPresent` is still ≤ 8, and it is not
        // reachable by any level or continuation threshold: reaching it means
        // suppressing the recovery handoff on genuine sustains, which is a different
        // mechanism (the median ring, or the display EMA) and out of scope here.
        #expect(split.whileSignalPresent <= 15,
                "The display changed state \(split.whileSignalPresent) times at or before \(String(format: "%.3f", Self.postMusicStart))s, the last strum (ratchet: 20, measured now 15). Aspiration: 8, which no level or continuation threshold reaches on this file.")

        // The tail is a separate question, and it is the one that was wrong.
        //
        // The music ends at 15.850 s. The recording then has 6.12 s of −46.3 dBFS
        // room tone, and the display used to be live on 274 of the tail's 287
        // frames — 5.85 s of it, 95 % — changing state 11 times and naming three
        // different strings (G4, C4, A4) out of silence. Continuation hysteresis
        // did not create it and could not remove it, and the two preceding reports
        // said so from opposite directions.
        //
        // **What the mechanism turned out to be**, since the guess on the table was
        // wrong in an instructive way. The hypothesis was a chicken-and-egg in the
        // adaptive noise gate: periodicity on noise keeps `lastForegroundTime`
        // fresh, the 0.35 s cooldown never expires, the floor never rises, so the
        // noise keeps looking periodic. Instrumented over the tail, **the floor is
        // not flat** — it climbs 0.00263 → 0.00428 and the cooldown expires dozens of
        // times, so adaptation is reachable and that specific story is refuted. What
        // is true is weaker and was the actual defect: the floor is an EMA of the
        // *non-foreground* subset of the room, and the frames of room tone that look
        // most periodic are also the loudest ones (their median is 1.90× the floor
        // against 1.37× for the tail as a whole), so the sample it learns from is
        // biased low. The floor settled at **0.77× the room's true mean**, and
        // `recommendedNoiseGate` therefore sat *below* that mean — not a gate at all.
        //
        // A level threshold alone could not repair it, and that is worth recording
        // because it is the tempting next step. A synthetic pluck mixed into this
        // room's own bed is still acquired at **1.49× the floor**, while the bed's
        // false acquisitions reach **4.76×**; the real recording's two marginal
        // re-acquisitions sit at 1.20× and 1.54×. Level, YIN periodicity and
        // frequency stability all overlap between the two populations, so no
        // threshold on `PitchResult` separates them. What did separate them was
        // *what the frame is allowed to do*: `isContinuingTarget` bypassed the
        // candidate requirement entirely, so a room-tone frame at 0.41× the floor
        // inside the prior's grace window reached `lastReadingTime` and restarted the
        // 1.0 s display hold, and the tail held itself up. Gating that shortcut and
        // candidate confirmation on a foreground test that includes the level takes
        // the tail from 274 live frames to 54.
        //
        // **54, and not 0, because 47 is what the hold costs on its own.** The same
        // file replayed with the room tone replaced by digital silence is live on 47
        // of the same 287 frames, because the last strum is still decaying at the
        // boundary and `readingHoldDuration` is 1.0 s. `postMusicTailIsAsDarkAsSilence`
        // measures that control in the suite, so 54 is a number with a meaning
        // rather than a number someone liked. What is left in the tail is two state
        // changes at 16.235 s and 17.003 s — the A4 finishing its decay, and the
        // same two changes the silenced control makes at 15.979 s and 16.853 s.
        #expect(split.afterMusicStops <= 2,
                "The display changed state \(split.afterMusicStops) times over \(String(format: "%.1f", split.tailSeconds))s of room tone after the last strum decayed (was 11): \(split.tail.joined(separator: ", ")). A tuner reporting at all here is wrong, not merely jittery.")
        #expect(split.tailLiveFrames <= 60,
                "The display was live on \(split.tailLiveFrames) of the tail's \(frames.count - frames.prefix { $0.captureEndSeconds <= Self.postMusicStart }.count) frames (\(String(format: "%.2f", split.tailLiveSeconds))s of \(String(format: "%.1f", split.tailSeconds))s); it was 274 before `PitchTracker.foregroundLevelMultiple`, and 47 is this file with the room tone removed, so anything near 274 is the room talking.")

        // Unchanged, and the assertion that carries the fix. 25 of 73 runs ≤ 2
        // frames (34%, median 107 ms) before; 0 of 29 after. Every survivor is ≥ 3
        // frames and is a real state change, so a needle that flips for 43 ms is
        // gone and the transitions that remain are not a subtler version of it.
        #expect(shortRuns.isEmpty,
                "\(shortRuns.count) of \(runs.count) non-`none` display runs lasted 2 frames or fewer (≤ 43 ms at the 1024-sample hop), lengths \(shortRuns.sorted().prefix(20)). A needle that is only briefly wrong still reads as a glitch.")
    }

    // MARK: - The tail, against its own control

    /// The post-music tail must be as dark as the same file with the room removed.
    ///
    /// "The display should not be live over room tone" is not the same claim as "the
    /// display should be dark from 15.850 s", and this test is what keeps the two
    /// apart. Zeroing the tail does not remove the last strum — it is still decaying
    /// at the boundary, and `PitchTracker.readingHoldDuration` holds the display for
    /// 1.0 s past the last frame the estimator had a pitch for. That is correct
    /// behaviour and it sets a floor on the honest measure, so the floor is measured
    /// here on the same file rather than asserted from memory.
    ///
    /// Measured: with the room tone, 54 live frames and 2 post-boundary transitions;
    /// with it replaced by silence, 47 and 2. The gate is on the *difference*, which
    /// is the only part the room tone is responsible for, and it is set at 12 frames
    /// (0.26 s, 4 % of the tail) against a measured 7. Before
    /// `PitchTracker.foregroundLevelMultiple` the difference was 224 frames.
    @Test("The post-music tail is as dark as the same file with the room tone removed")
    func postMusicTailIsAsDarkAsSilence() {
        guard let wav = AudioTestHelpers.loadWav(name: Self.fixtureName) else {
            Issue.record("Failed to load fixture \(Self.fixtureName).wav from StrumKitTests/Fixtures")
            return
        }

        let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .auto)
        let live = Self.transitionSplit(
            AudioTestHelpers.replayTrace(samples: wav.samples, sampleRate: wav.sampleRate, config: config).frames,
            boundary: Self.postMusicStart
        )
        let silenced = Self.transitionSplit(
            Self.silencedTail(wav: wav, config: config),
            boundary: Self.postMusicStart
        )

        let excessFrames = live.tailLiveFrames - silenced.tailLiveFrames
        print("TAILCONTROL|withRoom=\(live.tailLiveFrames)/\(Int(live.tailSeconds / 0.0213333 + 0.5)) frames, \(live.afterMusicStops) transitions (\(live.tail.joined(separator: ", ")))"
              + "|silenced=\(silenced.tailLiveFrames) frames, \(silenced.afterMusicStops) transitions (\(silenced.tail.joined(separator: ", ")))"
              + "|excess=\(excessFrames) frames")

        #expect(excessFrames <= 12,
                "The display was live on \(live.tailLiveFrames) frames of room tone against \(silenced.tailLiveFrames) for the same file silenced — \(excessFrames) frames (\(String(format: "%.2f", Double(excessFrames) * 0.0213333))s) of the tail are the room's doing. It was 224 before `PitchTracker.foregroundLevelMultiple`.")
        #expect(live.tailSeconds > 6.0,
                "This control is only meaningful if the tail is still the long silent stretch it is supposed to be; it is \(String(format: "%.2f", live.tailSeconds))s")
    }

    /// The level-qualified foreground test must cost the quiet plucks nothing.
    ///
    /// `PitchTracker.foregroundLevelMultiple` is the one number standing between
    /// "the display is dark over room tone" and "quiet plucks are still detected",
    /// and the two are not obviously compatible: a decaying pluck and a room-tone
    /// burst reach the same level, and the only thing that separates them is that
    /// one of them was asked for. So the cost side is asserted here, in the same
    /// file as the benefit, rather than being left to `RecordedAudioTests` — a
    /// future change that raises the multiple to 2.5 to buy a quieter tail must
    /// break a test that names what it is buying it with.
    ///
    /// The cliff is measured, not guessed. Sweeping the multiple over 1.0 … 5.0 with
    /// everything else fixed leaves every fixture below bit-identical at 1.0, 1.5 and
    /// 2.0, and then `quiet_a` falls from 86 fresh frames to 29 at 2.5 and 17 at
    /// 3.0, taking `RecordedAudioTests`' 0.40 s coverage gate to 0.62 s and 0.36 s.
    /// The 1.00 s floor here is roughly twice that gate, so there is room to absorb a
    /// little drift without the test going blind, and it still fails within one step
    /// of the shipped value.
    @Test("The level-qualified foreground test does not cost the quiet plucks their decay")
    func levelQualifiedForegroundKeepsQuietPlucks() {
        let fixtures: [(name: String, midi: Int)] = [
            ("quiet_a", 69), ("quiet_c", 60), ("quiet_e", 64), ("quiet_g", 67)
        ]

        for (name, midi) in fixtures {
            guard let wav = AudioTestHelpers.loadWav(name: name) else {
                Issue.record("Failed to load \(name).wav")
                continue
            }
            let config = TunerConfig(instrument: .ukulele, tuningId: "high-g", mode: .auto)
            let frames = AudioTestHelpers.replayTrace(
                samples: wav.samples, sampleRate: wav.sampleRate, config: config
            ).frames
            let reference = PitchMath.midiFrequency(midi, a4: config.a4)
            let fresh = frames.compactMap { $0.reading }.filter { $0.freshness == .fresh }
            let wrong = fresh.filter { !AudioTestHelpers.isCorrectRecordedPitch($0.frequency, reference: reference) }
            let coverage = AudioTestHelpers.freshCoverageSeconds(
                frames: frames, reference: reference,
                intervalStart: 0, intervalEnd: frames.last?.captureEndSeconds ?? 0
            )

            print(String(format: "QUIETPLUCK|%@|fresh=%d|wrongFresh=%d|coverage=%.3fs", name, fresh.count, wrong.count, coverage))

            #expect(wrong.isEmpty,
                    "\(name): the display named \(wrong.count) wrong fresh notes; suppressing room tone must not have made it more willing to guess")
            #expect(coverage >= 1.00,
                    "\(name): fresh coverage over its own length fell to \(String(format: "%.3f", coverage))s. `RecordedAudioTests` gates 0.40 s over a shorter window; this is roughly twice that, and it is the number that moves when `PitchTracker.foregroundLevelMultiple` is raised — it is 1.83 s at the shipped 2.0 and 0.62 s at 2.5.")
        }
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

        // These two were ceilings at numbers nobody could reconstruct — 112
        // transitions and 47 % short runs, recorded from an earlier build and left
        // as "do not regress" markers. The reconciliation report named them as this
        // file's last uninformed thresholds, and the level-qualified foreground test
        // is what makes them informable: chromatic has no string prior, so the
        // continuation tolerance had nothing to be sticky about, and 38 transitions
        // with 0 of 35 runs short is what the same recording produces once a frame
        // has to be louder than the room to reach the display. Measured here, both
        // are now ratchets at the values this file can reproduce.
        #expect(transitions <= 44,
                "Chromatic display changed state \(transitions) times over \(runs.count) runs; the measured value on this branch is 38 and the ceiling was an unreconstructible 112.")

        #expect(shortRate <= 0.05,
                "Chromatic short-run rate is \(Int(round(100 * shortRate)))% (\(shortRuns.count) of \(runs.count) runs ≤ 2 frames); the measured value on this branch is 0% and the ceiling was 47%.")
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

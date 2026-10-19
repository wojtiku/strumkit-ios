import Foundation
import Testing
@testable import StrumKit

/// A player turning a peg is a *moving* pitch: the string's frequency changes while
/// the tuner is watching it. Every recorded fixture in this suite is a string
/// sitting still, plucked once, so nothing here exercises the case the player
/// actually reports — that the needle does not follow the peg.
///
/// These tests synthesise that motion directly: a harmonic tone whose partials
/// glide, replayed at the live capture cadence through the same
/// `TunerAnalysisSession` the app runs, so a failure here is a failure in the real
/// path and not in a helper.
enum TuningResponsivenessHarness {

    /// One sample-accurate glide, with the partials kept phase-coherent.
    ///
    /// A naive `sin(2*pi*k*f(t)*t)` wobbles the harmonic structure during a sweep
    /// (its instantaneous frequency is `f + t*f'`, and `t*f'` is large by the end of
    /// a multi-second glide), which would make the fixture measure the synthesiser
    /// instead of the tuner. Accumulating the fundamental phase once and taking
    /// `k *` that as each partial's phase keeps every partial at exactly `k*f(t)`.
    static func glide(
        referenceHz: Double,
        rate: Double,
        seconds: Double,
        centsAt: (TimeInterval) -> Double,
        partials: [(ratio: Double, gain: Double)] = [(1, 0.09), (2, 0.15), (3, 0.055)],
        decaySeconds: Double = 6.0,
        noiseSnr: Double? = nil,
        seed: UInt64 = 7
    ) -> [Float] {
        let count = Int((rate * seconds).rounded())
        var out = [Float](repeating: 0, count: count)
        var phase = 0.0
        var dt = 1.0 / rate

        for i in 0..<count {
            let t = Double(i) / rate
            let cents = centsAt(t)
            let frequency = referenceHz * pow(2.0, cents / 1200.0)
            phase += 2.0 * Double.pi * frequency * dt

            let envelope = Float(exp(-t / decaySeconds))
            var value = 0.0
            for partial in partials {
                value += partial.gain * sin(partial.ratio * phase)
            }
            out[i] = envelope * Float(value)
        }

        guard let noiseSnr, noiseSnr.isFinite else { return out }

        var sumSq = 0.0
        for s in out { sumSq += Double(s * s) }
        let rms = sqrt(sumSq / Double(out.count))
        let noiseAmplitude = Float(rms * pow(10.0, -noiseSnr / 20.0) * sqrt(3.0))
        var lcg = seed % 2147483647
        if lcg == 0 { lcg = 1 }
        for i in 0..<out.count {
            lcg = (lcg &* 48271) % 2147483647
            out[i] += noiseAmplitude * Float((Double(lcg) / 2147483647.0) * 2.0 - 1.0)
        }
        return out
    }

    /// The frequency in hertz that the tuner's own cent arithmetic would call `cents`
    /// away from `referenceHz`. The inverse of `PitchMath.centsBetween`, written out
    /// so a fixture's ground truth cannot inherit a bug from the code under test.
    static func hz(referenceHz: Double, cents: Double) -> Double {
        referenceHz * pow(2.0, cents / 1200.0)
    }

    /// Repeated plucks at a moving pitch — the gesture of tuning itself.
    ///
    /// This is the shape none of the recorded fixtures have: pluck, turn the peg a
    /// little, pluck again, so every new attack lands *on top of* the previous note's
    /// decay and at a slightly different pitch. A tuner that has to re-acquire per
    /// pluck will trail the player here, and one that holds its last reading will
    /// trail them worse.
    ///
    /// - Returns: the samples, and the time of each pluck with the cents it sounded,
    ///   which is the ground truth a follow-latency measurement is taken against.
    static func tuningPlucks(
        referenceHz: Double,
        rate: Double,
        seconds: Double,
        centsAt: (TimeInterval) -> Double,
        pluckInterval: TimeInterval,
        decaySeconds: Double,
        partials: [(ratio: Double, gain: Double)] = [(1, 0.09), (2, 0.15), (3, 0.055)],
        noiseSnr: Double? = nil,
        seed: UInt64 = 11
    ) -> (samples: [Float], plucks: [(time: TimeInterval, cents: Double)]) {
        let count = Int((rate * seconds).rounded())
        var out = [Float](repeating: 0, count: count)
        var plucks: [(TimeInterval, Double)] = []

        var time = 0.0
        while time < seconds {
            let cents = centsAt(time)
            plucks.append((time, cents))
            let frequency = referenceHz * pow(2.0, cents / 1200.0)
            let start = Int((time * rate).rounded())
            let length = Int((rate * min(decaySeconds * 3.0, seconds - time)).rounded())
            var phase = 0.0
            for i in 0..<length {
                let t = Double(i) / rate
                phase += 2.0 * Double.pi * frequency / rate
                let envelope = Float(min(1.0, t / 0.006) * exp(-t / decaySeconds))
                var value = 0.0
                for partial in partials {
                    value += partial.gain * sin(partial.ratio * phase)
                }
                let index = start + i
                if index < count { out[index] += envelope * Float(value) }
            }
            time += pluckInterval
        }

        if let noiseSnr, noiseSnr.isFinite {
            var sumSq = 0.0
            for s in out { sumSq += Double(s * s) }
            let rms = sqrt(sumSq / Double(out.count))
            let amplitude = Float(rms * pow(10.0, -noiseSnr / 20.0) * sqrt(3.0))
            var lcg = seed % 2147483647
            if lcg == 0 { lcg = 1 }
            for i in 0..<out.count {
                lcg = (lcg &* 48271) % 2147483647
                out[i] += amplitude * Float((Double(lcg) / 2147483647.0) * 2.0 - 1.0)
            }
        }

        return (out, plucks.map { (time: $0.0, cents: $0.1) })
    }
}

@Suite("Tuning responsiveness")
struct TuningResponsivenessTests {

    /// A2 on a standard guitar: far from both neighbours, so nothing in this test
    /// can be explained by the closest-**String** search changing its mind.
    private static let a2 = 110.0

    private static func config(mode: TunerMode = .auto) -> TunerConfig {
        TunerConfig(instrument: .guitar, tuningId: "standard", mode: mode)
    }

    // MARK: - Scenario sweep

    struct Scenario {
        let name: String
        let centsAt: (TimeInterval) -> Double
        let seconds: Double
        let decaySeconds: Double
        let rePluck: Bool
        let noiseSnr: Double?
        let dropouts: Double
        let mode: TunerMode
    }

    /// One line per scenario: how much of the peg-turn the player actually saw, and
    /// how far the needle was from the truth while they saw it.
    private func summarise(_ scenario: Scenario) -> String {
        let rate = 44100.0
        let samples = TuningResponsivenessHarness.glide(
            referenceHz: Self.a2, rate: rate, seconds: scenario.seconds,
            centsAt: scenario.centsAt,
            decaySeconds: scenario.decaySeconds,
            noiseSnr: scenario.noiseSnr
        )
        let (frames, _) = AudioTestHelpers.replayTrace(
            samples: samples, sampleRate: rate, config: Self.config(mode: scenario.mode),
            yinDropoutRate: scenario.dropouts
        )

        // Judge only the steady middle: the first 0.5 s is acquisition and the
        // pipeline is not meant to have a reading yet.
        let start = 0.5
        let window = frames.filter { $0.captureEndSeconds >= start }
        guard !window.isEmpty else { return "\(scenario.name): no frames" }

        var dark = 0, pinned = 0, saturated = 0
        var errors: [Double] = []
        var displayErrors: [Double] = []
        for frame in window {
            let truth = scenario.centsAt(frame.captureEndSeconds)
            guard let reading = frame.reading else { dark += 1; continue }
            if !AudioTestHelpers.wasMeasuredThisFrame(reading) { pinned += 1 }
            errors.append(abs(reading.cents - truth))
            displayErrors.append(abs(reading.displayCents - truth))
            if abs(reading.displayCents) >= 49.9 { saturated += 1 }
        }
        errors.sort()
        let n = Double(window.count)
        let median = errors.isEmpty ? Double.nan : errors[errors.count / 2]
        let p95 = errors.isEmpty ? Double.nan : errors[min(errors.count - 1, Int(0.95 * Double(errors.count)))]
        let displayMedian = displayErrors.sorted().first ?? Double.nan

        return String(format: "%-34@ frames=%3d dark=%4.1f%% pinned=%4.1f%% sat=%4.1f%% |err| med=%6.2f p95=%7.2f  disp med=%6.2f  transitions=%d",
                       scenario.name as NSString,
                       window.count, 100 * Double(dark) / n, 100 * Double(pinned) / n,
                       100 * Double(saturated) / n, median, p95,
                       displayErrors.sorted()[displayErrors.count / 2],
                       AudioTestHelpers.countDisplayTransitions(window))
    }

    @Test("scenario sweep: what a peg-turn looks like from the tuner's side")
    func scenarioSweep() {
        let scenarios: [Scenario] = [
            Scenario(name: "slow glide -60..+60 over 6s", centsAt: { -60 + 120 * $0 / 6 },
                     seconds: 7, decaySeconds: 6, rePluck: false, noiseSnr: nil,
                     dropouts: 0, mode: .auto),
            Scenario(name: "fast turn 100c in 0.5s", centsAt: { -50 + 200 * min(1, $0 / 0.5) },
                     seconds: 1.5, decaySeconds: 6, rePluck: false, noiseSnr: nil,
                     dropouts: 0, mode: .auto),
            Scenario(name: "wide sweep -250..+250 over 8s", centsAt: { -250 + 500 * $0 / 8 },
                     seconds: 9, decaySeconds: 6, rePluck: false, noiseSnr: nil,
                     dropouts: 0, mode: .auto),
            Scenario(name: "slow glide, decaying like a pluck", centsAt: { -60 + 120 * $0 / 6 },
                     seconds: 7, decaySeconds: 1.2, rePluck: false, noiseSnr: nil,
                     dropouts: 0, mode: .auto),
            Scenario(name: "slow glide, 20dB room tone", centsAt: { -60 + 120 * $0 / 6 },
                     seconds: 7, decaySeconds: 6, rePluck: false, noiseSnr: 20,
                     dropouts: 0, mode: .auto),
            Scenario(name: "slow glide, 25% YIN dropouts", centsAt: { -60 + 120 * $0 / 6 },
                     seconds: 7, decaySeconds: 6, rePluck: false, noiseSnr: nil,
                     dropouts: 0.25, mode: .auto),
            Scenario(name: "slow glide, chromatic", centsAt: { -60 + 120 * $0 / 6 },
                     seconds: 7, decaySeconds: 6, rePluck: false, noiseSnr: nil,
                     dropouts: 0, mode: .chromatic),
            Scenario(name: "slow glide, locked A2", centsAt: { -60 + 120 * $0 / 6 },
                     seconds: 7, decaySeconds: 6, rePluck: false, noiseSnr: nil,
                     dropouts: 0, mode: .manual),
        ]

        print("== SCENARIO SWEEP ==")
        for scenario in scenarios {
            print(summarise(scenario))
        }
    }

    /// The question a player is actually asking: the peg has stopped moving, the
    /// string is sitting at a new pitch — how long until the needle agrees?
    ///
    /// This is deliberately *not* the continuous glide above. A glide and a step
    /// stress different things, and only one of them is what the player does: a peg
    /// turn ends, and the interesting measurement is the settling time from the
    /// moment the new pitch sounds. Ground truth is a constant per trial, so "agrees"
    /// is unambiguous.
    ///
    /// Latency is the first frame whose reading is within `tolerance` of the new
    /// pitch **and stays** within it for the rest of the trial — the sustain
    /// requirement matters, because a display that touches the right value for one
    /// frame and then drifts back has not told the player anything.
    @Test("settling time: pitch steps to a new value and stops")
    func settlingTime() {
        let rate = 44100.0
        // Each trial: sound at `from` for a beat, then at `to` forever after. A real
        // peg turn, minus the decay overlap that would make "which note is sounding"
        // ambiguous — the previous string's ring is modelled by the separate
        // dropout-free decay below rather than by two pitches at once.
        let trials: [(label: String, from: Double, to: Double, stepAt: Double)] = [
            ("-60 -> -55, step at 1.0s", -60, -55, 1.0),
            ("-30 -> -10, step at 1.0s", -30, -10, 1.0),
            ("+40 -> +12, step at 1.0s", 40, 12, 1.0),
            ("-60 -> -5,  step at 0.3s", -60, -5, 0.3),
            ("+15 -> +2,  step at 2.0s", 15, 2, 2.0),
        ]
        let tolerance = 5.0

        for trial in trials {
            let seconds = trial.stepAt + 3.0
            let samples = TuningResponsivenessHarness.glide(
                referenceHz: Self.a2, rate: rate, seconds: seconds,
                centsAt: { t in t < trial.stepAt ? trial.from : trial.to },
                decaySeconds: 8.0
            )
            let (frames, _) = AudioTestHelpers.replayTrace(
                samples: samples, sampleRate: rate, config: Self.config()
            )

            let after = frames.filter { $0.captureEndSeconds >= trial.stepAt }
            let settledAt = after.first { frame in
                guard let r = frame.reading, abs(r.cents - trial.to) <= tolerance else { return false }
                return after
                    .filter { $0.captureEndSeconds >= frame.captureEndSeconds }
                    .allSatisfy { $0.reading.map { abs($0.cents - trial.to) <= tolerance } ?? false }
            }?.captureEndSeconds

            let latency = settledAt.map { $0 - trial.stepAt }
            print(String(format: "@@ SETTLE %-26@ -> %6.1fc  latency=%@  (%d frames after step)",
                         trial.label as NSString, trial.to,
                         latency.map { String(format: "%.3fs", $0) } ?? "NEVER" as NSString,
                         after.count))
        }
    }

    /// The symptom a player actually reports, measured on the string they tune most.
    ///
    /// A tuning session is a sequence of plucks, each at a slightly different pitch,
    /// and between the plucks the previous note is still decaying. Two questions, and
    /// they are different questions:
    ///
    /// 1. **Settling**: after a pluck at a new pitch, how long until the display
    ///    agrees with it?
    /// 2. **Staleness** — the one that matches "it doesn't react when I turn the peg":
    ///    how long is the display showing the *previous* pitch while the new one is
    ///    sounding? A tuner can be within a few cents of the truth on average and
    ///    still feel dead, if the value the player is looking at is a remembered one
    ///    for a third of a second at a time.
    ///
    /// Run on the **low E** rather than A2 deliberately: it is the string players tune
    /// first, and at 82.4 Hz the analysis window holds the fewest periods of any
    /// string on the instrument, so it is where a tuning-specific failure would show
    /// up first.
    @Test("tuning session: settling and staleness on the low E")
    func tuningSession() {
        let rate = 44100.0
        let lowE = 82.4069

        for (label, interval, decay, snr) in [
            ("pluck 1.5s, decay 2.5s, clean", 1.5, 2.5, nil as Double?),
            ("pluck 1.5s, decay 2.5s, 15dB noise", 1.5, 2.5, 15.0),
            ("pluck 2.0s, decay 3.0s, clean", 2.0, 3.0, nil as Double?),
        ] {
            // Each pluck 8 cents nearer in tune: 12 plucks over 18 s, -48 -> +40.
            let fixture = TuningResponsivenessHarness.tuningPlucks(
                referenceHz: lowE, rate: rate, seconds: 18.0,
                centsAt: { t in -48.0 + 88.0 * (t / 18.0) },
                pluckInterval: interval, decaySeconds: decay, noiseSnr: snr
            )
            let (frames, _) = AudioTestHelpers.replayTrace(
                samples: fixture.samples, sampleRate: rate, config: Self.config()
            )

            var settles: [Double] = []
            var staleFraction = 0.0
            var judged = 0
            for (index, pluck) in fixture.plucks.enumerated() {
                let end = Double(fixture.samples.count) / rate
                let next = fixture.plucks.indices.contains(index + 1)
                    ? fixture.plucks[index + 1].time
                    : end
                guard next - pluck.time > 0.2 else { continue }
                let span = frames.filter {
                    $0.captureEndSeconds >= pluck.time && $0.captureEndSeconds < next
                }
                guard !span.isEmpty else { continue }
                judged += 1

                // Staleness: frames showing a pitch that is not this pluck's, while
                // this pluck's is what is sounding. "Wrong" is anything more than
                // 10 cents from the new pitch — a fifth is 500, a whole tone is 200,
                // so this is a generous definition of "not the note I just played".
                let wrong = span.filter { frame in
                    guard let r = frame.reading else { return false }
                    return abs(r.cents - pluck.cents) > 10
                }.count
                staleFraction += Double(wrong) / Double(span.count)

                // "Settled" means within tolerance and *staying* there for 250 ms —
                // long enough that the player would have read it, without demanding
                // perfection for the whole interval. Requiring it to hold to the end of
                // the interval measures the last moment it became right, which is a
                // different and much larger number than the one a player experiences.
                if let settled = span.first(where: { frame in
                    guard let r = frame.reading, abs(r.cents - pluck.cents) <= 5 else { return false }
                    let until = frame.captureEndSeconds + 0.25
                    return span
                        .filter {
                            $0.captureEndSeconds >= frame.captureEndSeconds
                                && $0.captureEndSeconds < until
                        }
                        .allSatisfy { $0.reading.map { abs($0.cents - pluck.cents) <= 5 } ?? false }
                }) {
                    settles.append(settled.captureEndSeconds - pluck.time)
                }
            }
            settles.sort()
            print(String(format: "@@ SESSION %-32@ plucks=%2d  settle med=%.3fs p90=%.3fs worst=%.3fs  stale=%.1f%%",
                         label as NSString, judged,
                         settles.isEmpty ? -1 : settles[settles.count / 2],
                         settles.isEmpty ? -1 : settles[min(settles.count - 1, Int(0.9 * Double(settles.count)))],
                         settles.last ?? -1,
                         judged > 0 ? 100 * staleFraction / Double(judged) : -1))
        }
    }

    /// The two failure shapes that a *sustained* glide cannot show, because both need
    /// the pitch to sit still while the tuner's decisions change around it.
    ///
    /// **String identity.** In **Auto** mode the tuner has to decide which **String**
    /// the player is aiming at. Sit a pitch near the midpoint between two strings and
    /// it is a coin toss which one it names — and a player tuning *is* doing exactly
    /// that whenever a string is a whole tone out and they are bringing it in. The
    /// symptom is the app appearing to ignore the peg, because the cents it prints
    /// are measured from whichever string it picked this frame.
    ///
    /// **The in-tune latch.** `lastInTuneState` gives the enter tolerance (5¢) and the
    /// exit tolerance (7¢) a direction, so a reading sitting at the boundary can hold
    /// one verdict while the pitch is visibly moving past it.
    @Test("auto mode: which string is it aiming at, while the pitch moves")
    func autoModeStringIdentity() {
        let rate = 44100.0

        // The midpoint between A2 (110 Hz) and D3 (146.83 Hz) is 127.2 Hz. A player
        // bringing a detuned string in through this region crosses it.
        let midpoint = sqrt(110.0 * 146.8324)
        print(String(format: "@@ auto midpoint A2/D3 = %.3f Hz", midpoint))

        for (label, cents) in [
            ("parked exactly on the midpoint", 0.0),
            ("wobbling +-3 cents on the midpoint", 3.0),
            ("wobbling +-25 cents around the midpoint", 25.0),
        ] {
            let wobble: (TimeInterval) -> Double = { t in
                cents * sin(2.0 * Double.pi * 0.8 * t)
            }
            let samples = TuningResponsivenessHarness.glide(
                referenceHz: midpoint, rate: rate, seconds: 8.0,
                centsAt: wobble, decaySeconds: 8.0
            )
            let (frames, _) = AudioTestHelpers.replayTrace(
                samples: samples, sampleRate: rate, config: Self.config()
            )

            var names: [String: Int] = [:]
            var signFlips = 0
            var inTuneFlips = 0
            var previousCents: Double?
            var previousInTune: Bool?
            for frame in frames where frame.captureEndSeconds > 1.0 {
                guard let r = frame.reading else { continue }
                names[r.note, default: 0] += 1
                if let previousCents {
                    let forward = (previousCents < 0) != (r.cents < 0)
                    if forward, abs(r.cents) < 200 { signFlips += 1 }
                }
                previousCents = r.cents
                if let previousInTune, previousInTune != (r.inTune ?? false) { inTuneFlips += 1 }
                previousInTune = r.inTune
            }
            print(String(format: "@@ IDENTITY %-38@ names=%@  zeroCrossings=%d  inTuneFlips=%d",
                         label as NSString,
                         "\(names.sorted { $0.value > $1.value })" as NSString,
                         signFlips, inTuneFlips))
        }
    }

    /// **The Auto-mode dead band, measured.**
    ///
    /// `TunerAnalysisSession` finds the closest **String** in **Auto** mode and accepts
    /// the reading only if it is within `TunerConstants.maxDetuningCents` (200) of it.
    /// In standard guitar tuning adjacent strings are 500 cents apart, so the point
    /// exactly between two strings is 250 cents from each — and 250 > 200. There is
    /// therefore a band, 100 cents wide, centred on every midpoint, where the closest
    /// string is too far away for the reading to be accepted at all.
    ///
    /// That band is not an edge case: it is where a string sits when it is between one
    /// and two semitones out, which is precisely where a string is when a player
    /// starts turning the peg. And because a rejected frame falls through to
    /// `handleLostSignal`, the display does not go blank — it **holds the previous
    /// reading for a second**, de-emphasised. So the player turns the peg, the pitch
    /// moves measurably, and the needle sits frozen on the value from before.
    ///
    /// This test maps the band by sweeping a held pitch across one midpoint in 5-cent
    /// steps and asking, at each step, whether the display produces a *fresh* reading.
    @Test("auto mode: the dead band between two strings")
    func autoModeDeadBand() {
        let rate = 44100.0
        let midpoint = sqrt(110.0 * 146.8324)   // A2 / D3
        let config = Self.config()

        var dead: [Int] = []
        var deadDetail: [(Int, Double, Int, Int)] = []
        var alive: [Int] = []
        var heldInsteadOfFresh = 0

        // -60 .. +60 cents around the midpoint, in 5-cent steps.
        for step in stride(from: -60, through: 60, by: 5) {
            let cents = Double(step)
            let samples = TuningResponsivenessHarness.glide(
                referenceHz: midpoint, rate: rate, seconds: 3.0,
                centsAt: { _ in cents }, decaySeconds: 8.0
            )
            let (frames, _) = AudioTestHelpers.replayTrace(
                samples: samples, sampleRate: rate, config: config
            )
            // Judge the steady middle, after acquisition has had time to complete.
            let judged = frames.filter { $0.captureEndSeconds > 1.0 }
            let fresh = judged.filter { frame in
                guard let r = frame.reading else { return false }
                return AudioTestHelpers.wasMeasuredThisFrame(r)
            }
            // What the *estimator* heard, independent of whether the tracker accepted
            // it. This is the diagnostic that separates "the detector lost the pitch"
            // from "the tracker refused the pitch it was given" — the two have
            // completely different fixes and look identical on screen.
            let heard = judged.filter { $0.rawFrequency > 0 }
            let heardMedian = heard.isEmpty
                ? 0
                : heard.map { $0.rawFrequency }.sorted()[heard.count / 2]
            if fresh.count > judged.count / 4 {
                alive.append(step)
            } else {
                dead.append(step)
                deadDetail.append((step, heardMedian, heard.count, judged.count))
                if judged.contains(where: { $0.reading != nil }) { heldInsteadOfFresh += 1 }
            }
        }

        print("@@ DEADBAND alive cents offsets: \(alive)")
        print("@@ DEADBAND dead  cents offsets: \(dead)")
        for (step, hz, heardCount, judgedCount) in deadDetail {
            print(String(format: "@@ DEADBAND   %+4d¢  estimator heard %7.3f Hz on %d/%d frames (truth %.3f Hz)",
                         step, hz, heardCount, judgedCount,
                         TuningResponsivenessHarness.hz(referenceHz: midpoint, cents: Double(step))))
        }
        print("@@ DEADBAND of \(dead.count) dead offsets, \(heldInsteadOfFresh) showed a held reading instead of blank")
        print("@@ DEADBAND => \(TunerConstants.maxDetuningCents)¢ gate vs 250¢ string spacing: "
              + "\(max(0, 2 * (250 - Int(TunerConstants.maxDetuningCents))))¢ dead per midpoint")

        // The assertion, stated as the property rather than the number: inside the
        // band a moving pitch must not leave the display showing a remembered reading.
        #expect(dead.count > 0, "expected a dead band between two strings in Auto mode")
    }

    /// The symptom, end to end: a player turns the peg and the needle stops.
    ///
    /// A pitch that starts in tune with A2, detunes steadily through the midpoint
    /// between A2 and D3, and comes to rest 40 cents sharp of the midpoint. The whole
    /// move is 340 cents, which is less than a minor third — an ordinary tuning
    /// correction, and the kind of turn a player makes without thinking about it.
    ///
    /// The pitch is estimated accurately on every frame throughout (asserted below),
    /// so nothing here is a detection failure. What is measured is what the *display*
    /// does while the pitch is moving underneath it.
    @Test("symptom: needle freezes while the pitch crosses the dead band")
    func needleFreezesWhileCrossingDeadBand() {
        let rate = 44100.0
        let startHz = 110.0                                  // A2, in tune
        let endCentsFromMidpoint = 40.0
        let midpoint = sqrt(110.0 * 146.8324)
        let endHz = TuningResponsivenessHarness.hz(
            referenceHz: midpoint, cents: endCentsFromMidpoint
        )
        let travelCents = 1200.0 * log2(endHz / startHz)
        let seconds = 6.0

        print(String(format: "@@ FREEZE sweeping A2 %.1f Hz -> %.1f Hz (%.0f cents) over %.1fs",
                     startHz, endHz, travelCents, seconds))

        let samples = TuningResponsivenessHarness.glide(
            referenceHz: startHz, rate: rate, seconds: seconds,
            centsAt: { travelCents * $0 / seconds },
            decaySeconds: 8.0
        )
        let (frames, _) = AudioTestHelpers.replayTrace(
            samples: samples, sampleRate: rate, config: Self.config()
        )

        var lastShownCents: Double?
        var frozenWindows: [(from: Double, to: Double, shownCents: Double)] = []
        var freezeStart: (time: Double, shown: Double)?
        var heardEverywhere = true
        var inBandLog: [String]? = nil
        var darkFrames = 0
        var staleFrames = 0

        for frame in frames {
            let truth = travelCents * frame.captureEndSeconds / seconds
            let truthHz = TuningResponsivenessHarness.hz(referenceHz: startHz, cents: truth)
            let offsetFromMidpoint = 1200.0 * log2(truthHz / midpoint)

            // The estimator heard the pitch throughout — measured against the average
            // of the analysis window rather than its trailing edge, because a window
            // estimates the pitch *within* it. On a glide that predicts a fixed lag of
            // half a window, so the bar is "no worse than the geometry allows" plus a
            // cent for the estimator's own error. Anything beyond that is a detection
            // failure, and would make the freeze a symptom of something else.
            //
            // Half the analysis window in cents of glide, at the local glide rate.
            let windowSeconds = Double(Resampler.windowSize) / Resampler.analysisRate
            let glideRate = travelCents / seconds
            let expectedLag = glideRate * windowSeconds / 2.0
            if frame.rawFrequency > 0,
               abs(1200.0 * log2(frame.rawFrequency / truthHz)) > expectedLag + 1.0 {
                heardEverywhere = false
                if inBandLog == nil { inBandLog = [] }
                inBandLog!.append(String(format: "      t=%.3f truth=%.3f heard=%.3f (%.2f cents off, bar %.2f)",
                                          frame.captureEndSeconds, truthHz, frame.rawFrequency,
                                          1200.0 * log2(frame.rawFrequency / truthHz),
                                          expectedLag + 1.0))
            }

            // Inside the dead band the tracker has no String to measure against, so it
            // publishes the *previous* reading. The player sees a number that is not
            // moving while the pitch underneath it is.
            let inBand = abs(offsetFromMidpoint) < 45
            guard inBand, frame.captureEndSeconds > 1.0 else {
                if let window = freezeStart {
                    frozenWindows.append((window.time, frame.captureEndSeconds, window.shown))
                    freezeStart = nil
                }
                lastShownCents = nil
                continue
            }

            guard let reading = frame.reading else {
                darkFrames += 1
                lastShownCents = nil
                continue
            }
            if !AudioTestHelpers.wasMeasuredThisFrame(reading) { staleFrames += 1 }
            if let shown = lastShownCents, abs(shown - reading.cents) < 0.5 {
                // Unchanged value while the truth moved.
                if freezeStart == nil { freezeStart = (frame.captureEndSeconds, reading.cents) }
            } else {
                if let window = freezeStart {
                    frozenWindows.append((window.time, frame.captureEndSeconds, window.shown))
                }
                freezeStart = nil
            }
            lastShownCents = reading.cents
        }
        if let window = freezeStart, let last = frames.last {
            frozenWindows.append((window.time, last.captureEndSeconds, window.shown))
        }

        for window in frozenWindows {
            print(String(format: "@@ FREEZE   %.3fs..%.3fs  needle held at %.2f cents (%.2fs frozen)",
                         window.from, window.to, window.shownCents, window.to - window.from))
        }
        let totalFrozen = frozenWindows.reduce(0.0) { $0 + ($1.to - $1.from) }
        print(String(format: "@@ FREEZE total frozen %.2fs of dead-band time; dark=%d stale=%d",
                     totalFrozen, darkFrames, staleFrames))

        for line in inBandLog ?? [] { print(line) }
        print("@@ FREEZE estimator accurate on every frame: \(heardEverywhere)")

        // Two claims, and they are the diagnosis:
        //  - the estimator tracked the pitch, so the pitch pipeline is not the problem
        //  - the display froze anyway, which is the reported symptom
        #expect(heardEverywhere, "estimator lost the pitch while crossing the dead band")
        #expect(
            totalFrozen > 0.3,
            "expected the needle to freeze for a noticeable time inside the dead band, got \(totalFrozen)s"
        )
    }

    /// **Fluency**, which is a different question from settling.
    ///
    /// Settling asks *how long until the value is right*. Fluency asks whether the
    /// value **moves continuously** while the player is turning the peg — no stalls
    /// where the needle sits still while the pitch moves, and no jumps where it
    /// teleports. A tuner can settle fast and still feel dead if the path between
    /// −20 and 0 is a staircase.
    ///
    /// Two metrics, both per-frame, because either alone can be gamed:
    ///
    /// - **stall**: a frame where the displayed value did not move although the true
    ///   pitch did. This is what "not reacting" looks like frame by frame.
    /// - **jump**: the largest single-frame change. Smooth motion is many small steps;
    ///   a jump is the display being re-inserted rather than moved.
    ///
    /// Ground truth is a smooth ramp, so both are meaningful without judgement calls
    /// about which frames "should" have moved.
    @Test("fluency: does the value move continuously from -20 cents to 0?")
    func fluency() {
        let rate = 44100.0
        let tolerance = 0.5   // a stall is "did not move at all", not "moved a little"

        struct Fluency { var stalls = 0; var worstStallRun = 0; var maxJump = 0.0; var stallSeconds = 0.0 }

        func measure(frames: [AudioTestHelpers.ReplayFrame], truth: (Double) -> Double)
            -> Fluency {
            var result = Fluency()
            var previousShown: Double?
            var previousTruth: Double?
            var previousTime: Double?
            var run = 0
            for frame in frames {
                let t = frame.captureEndSeconds
                let trueCents = truth(t)
                defer {
                    previousShown = frame.reading?.displayCents
                    previousTruth = trueCents
                    previousTime = t
                }
                guard let shown = frame.reading?.displayCents,
                      let previousShown, let previousTruth, let previousTime
                else { continue }

                let truthMoved = trueCents - previousTruth
                let shownMoved = shown - previousShown
                if abs(truthMoved) > tolerance, abs(shownMoved) < tolerance * 0.2 {
                    result.stalls += 1
                    result.stallSeconds += t - previousTime
                    run += 1
                    result.worstStallRun = max(result.worstStallRun, run)
                } else {
                    run = 0
                }
                result.maxJump = max(result.maxJump, abs(shownMoved))
            }
            return result
        }

        // The gesture the player describes: bringing a string in from 20 cents flat.
        // Swept slowly, as a peg turn actually is.
        let ramp: (TimeInterval) -> Double = { t in -20.0 * (1.0 - min(1.0, t / 4.0)) }
        let glide = TuningResponsivenessHarness.glide(
            referenceHz: Self.a2, rate: rate, seconds: 5.0,
            centsAt: ramp, decaySeconds: 8.0
        )
        let (glideFrames, _) = AudioTestHelpers.replayTrace(
            samples: glide, sampleRate: rate, config: Self.config()
        )
        let g = measure(frames: glideFrames, truth: ramp)
        print(String(format: "@@ FLUENCY continuous glide   stalls=%3d (%.2fs)  worstRun=%2d  maxJump=%.2f cents",
                     g.stalls, g.stallSeconds, g.worstStallRun, g.maxJump))

        // The same move done the way a player does it: re-pluck as you go. Each pluck
        // is at a slightly different pitch, the previous one still decaying. This is
        // where a display that re-acquires per pluck would show its stalls.
        let stepCents: (TimeInterval) -> Double = { t in
            let step = Int(t / 0.3)
            return -20.0 + Double(step)
        }
        let plucks = TuningResponsivenessHarness.tuningPlucks(
            referenceHz: Self.a2, rate: rate, seconds: 6.3,
            centsAt: { -20.0 + min(20.0, floor($0 / 0.3)) },
            pluckInterval: 0.3, decaySeconds: 1.8
        )
        let (pluckFrames, _) = AudioTestHelpers.replayTrace(
            samples: plucks.samples, sampleRate: rate, config: Self.config()
        )
        let p = measure(frames: pluckFrames, truth: stepCents)
        print(String(format: "@@ FLUENCY re-plucked every 0.3s stalls=%3d (%.2fs)  worstRun=%2d  maxJump=%.2f cents",
                     p.stalls, p.stallSeconds, p.worstStallRun, p.maxJump))

        // Per-frame trace of the re-plucked move, which is where the jumps and stalls
        // are. The continuous glide is summarised above because it has nothing to show.
        print("-- per-frame, re-plucked every 0.3s: -20 -> 0 --")
        var lastShown: Double?
        for frame in pluckFrames where frame.captureEndSeconds > 0.05 {
            let t = frame.captureEndSeconds
            let r = frame.reading
            let shown: Double? = r?.displayCents
            let delta: Double = shown.flatMap { value in lastShown.map { value - $0 } } ?? 0
            let mark: String
            if let shown, let previous = lastShown {
                if abs(shown - previous) > 5.0 {
                    mark = "  <== JUMP"
                } else if abs(shown - previous) < 0.1,
                          abs(stepCents(t) - stepCents(t - 0.023)) > 0.05 {
                    mark = "  <== STALL"
                } else {
                    mark = ""
                }
            } else {
                mark = ""
            }
            print(String(format: "   t=%5.3f truth=%7.2f  cents=%@  disp=%@  d=%6.2f  %-7@ %-12@%@",
                         t, stepCents(t),
                         r.map { String(format: "%7.2f", $0.cents) } ?? "   nil" as NSString,
                         shown.map { String(format: "%7.2f", $0) } ?? "   nil" as NSString,
                         delta, frame.displayState as NSString,
                         (frame.rejection ?? "-") as NSString, mark as NSString))
            lastShown = shown
        }

        // At 47 frames/s a smooth move should be well under a cent per frame; a stall
        // is a value that stood still while the pitch did not.
        #expect(
            g.stallSeconds < 0.15,
            "needle stalled for \(g.stallSeconds)s while the pitch moved continuously"
        )
        #expect(
            g.maxJump < 5.0,
            "needle jumped \(g.maxJump) cents in one frame; that is a re-insert, not motion"
        )
    }

    /// The one thing a synchronous replay cannot tell you: **how often the live
    /// pipeline actually produces a new value.**
    ///
    /// `replayTrace` calls `processFrameSync` in a loop, so it analyses every 23 ms
    /// window and hands every result straight to the tracker. The live path does not:
    /// the tap enqueues, a serial worker drains a **mailbox of capacity one**, and a
    /// result that arrives while the worker is busy *replaces* whatever was waiting.
    ///
    /// So the live display rate is not the capture rate — it is the rate the DSP can
    /// sustain, and the two are equal only while DSP is faster than a hop. When it is
    /// not, the needle is fed a coarser stream than the tracker was measured on, and a
    /// smooth peg turn becomes a staircase — which is exactly the reported symptom,
    /// and exactly the thing every other test here is blind to.
    ///
    /// This measures the DSP cost per frame on this machine, and turns it into the
    /// frame rate the display can actually get.
    @Test("live cadence: can the worker keep up with a 23 ms hop?")
    func liveCadenceBudget() {
        let rate = 44100.0
        let hop = AudioTestHelpers.productionHopSamples
        let hopMs = 1000.0 * Double(hop) / rate

        // A representative hard case: the low E, loud, with the spectral scorer armed —
        // the configuration where `detectPitch` does the most work.
        let samples = TuningResponsivenessHarness.glide(
            referenceHz: 82.4069, rate: rate, seconds: 3.0,
            centsAt: { _ in 0 }, decaySeconds: 30.0
        )
        let windowLength = Resampler.requiredInputSamples(for: rate)

        let session = TunerAnalysisSession(config: Self.config(), targets: [])
        session.start(config: Self.config(), targets: Tuning.resolve(
            instrument: .guitar, tuningId: "standard",
            customMidi: [40, 45, 50, 55, 59, 64],
            mode: .auto, a4: 440, precision: false, guided: false, selectedString: 0
        ).targets)

        var dspTimes: [Double] = []
        var sequence: UInt64 = 0
        for endSample in stride(from: windowLength, through: samples.count, by: hop) {
            sequence &+= 1
            let window = Array(samples[(endSample - windowLength)..<endSample])
            let frame = AnalysisFrame(
                samples: window, sampleRate: rate,
                captureEndSeconds: Double(endSample) / rate,
                sequence: sequence, generation: session.generation,
                callbackFrameCount: hop
            )
            guard let snapshot = session.processFrameSync(frame) else { continue }
            dspTimes.append(snapshot.diagnostics.dspMs)
        }

        guard !dspTimes.isEmpty else {
            Issue.record("no frames analysed")
            return
        }
        let sorted = dspTimes.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(0.95 * Double(sorted.count)))]
        let worst = sorted.last ?? 0

        // The pipeline sustains a hop's worth of audio only if the median DSP cost
        // leaves room inside it.
        let medianHeadroom = hopMs / median
        let worstHeadroom = hopMs / worst

        print(String(format: "@@ CADENCE hop=%.2fms  frames=%d  dsp median=%.3fms p95=%.3fms worst=%.3fms",
                     hopMs, dspTimes.count, median, p95, worst))
        print(String(format: "@@ CADENCE headroom: median %.1fx, worst %.1fx of the hop budget",
                     medianHeadroom, worstHeadroom))
        print(String(format: "@@ CADENCE => live display rate is at most %.0f fps (median), %.0f fps (worst)",
                     1000.0 / median, 1000.0 / worst))
        print(String(format: "@@ CADENCE    and at most %.0f fps if the worker only starts the next frame on the previous one finishing",
                     1000.0 / (median + hopMs / 1000.0 * 0.0 + hopMs / 1000.0)))

        #expect(
            median < hopMs * 0.5,
            "median DSP \(median)ms against a \(hopMs)ms hop: the worker cannot keep up, so the display is fed a coarser stream than the tracker was measured on"
        )
    }

    /// The player's own recording: the G string turned up and down repeatedly until
    /// it is in tune.
    ///
    /// Nothing is synthesised here, so this is the only fixture in the suite that
    /// carries what a peg turn actually does to a real string — the player said they
    /// expect the arrow to follow, and the question is whether it does.
    @Test("recording: tuning_g.m4a, G string turned up and down")
    func recordedTuningSession() {
        guard let wav = AudioTestHelpers.loadWav(name: "tuning_g") else {
            Issue.record("tuning_g.wav fixture missing")
            return
        }
        let rate = wav.sampleRate
        let samples = wav.samples
        print(String(format: "@@ RECORDING tuning_g: %.1f s @ %.0f Hz, %d samples, peak=%.4f",
                     Double(samples.count) / rate, rate, samples.count,
                     samples.reduce(Float(0)) { max($0, abs($1)) }))

        // G3 on a standard guitar is midi 55. The player is tuning *this* string.
        let g3 = 195.9977
        let config = Self.config()
        let (frames, tracker) = AudioTestHelpers.replayTrace(
            samples: samples, sampleRate: rate, config: config
        )
        guard !frames.isEmpty else {
            Issue.record("no frames replayed")
            return
        }

        // Per-frame trace. `heard` is what the estimator produced; `shown` is what the
        // player saw. The gap between those two columns is the whole question.
        print("--   t   heardHz  fromG3   shown arrow state    reject            rms --")
        for frame in frames {
            let t = frame.captureEndSeconds
            let heardCents = frame.rawFrequency > 0
                ? 1200.0 * log2(frame.rawFrequency / g3)
                : Double.nan
            let r = frame.reading
            let shown = r?.cents ?? Double.nan
            let arrow = r.map { $0.cents < 0 ? "v" : "^" } ?? "-"
            print([
                String(format: "%6.3f", t),
                String(format: "%9.3f", frame.rawFrequency),
                String(format: "%9.2f", heardCents),
                String(format: "%10.2f", shown),
                "\(arrow) \(frame.displayState) \((frame.rejection ?? "-"))",
            ].joined(separator: " "))
        }

        // Summary: where the player was turning the peg, was the arrow moving?
        let dark = frames.filter { $0.reading == nil }.count
        let held = frames.filter { frame in
            guard let r = frame.reading else { return false }
            return !AudioTestHelpers.wasMeasuredThisFrame(r)
        }.count
        let heardPitch = frames.filter { $0.rawFrequency > 0 }.count
        print(String(format: "@@ RECORDING frames=%d  dark=%d (%.1f%%)  pinned=%d (%.1f%%)  estimator heard a pitch on %d (%.1f%%)",
                     frames.count, dark, 100.0 * Double(dark) / Double(frames.count),
                     held, 100.0 * Double(held) / Double(frames.count),
                     heardPitch, 100.0 * Double(heardPitch) / Double(frames.count)))
        print("@@ RECORDING tracker state: \(tracker.feedbackState)")

        // A rough level profile, so the shape of the session is legible: the player
        // plucks, the note decays, they turn the peg, they pluck again.
        let bucketSeconds = 0.5
        let buckets = Int(Double(samples.count) / rate / bucketSeconds)
        var profile: [String] = []
        for b in 0..<buckets {
            let lo = b * Int(bucketSeconds * rate)
            let hi = min(samples.count, lo + Int(bucketSeconds * rate))
            guard hi > lo else { break }
            let slice = samples[lo..<hi]
            let peak = slice.reduce(Float(0)) { max($0, abs($1)) }
            profile.append(String(format: "%.1f", peak))
        }
        print("@@ RECORDING peak per 0.5s: \(profile.joined(separator: " "))")
    }

    /// The recorded session's central question: **is the estimator reporting the G
    /// string an octave up?**
    ///
    /// The trace shows a detected pitch that moves between roughly 370 and 390 Hz
    /// across the whole session — a 92-cent range that tracks the peg turn, so the
    /// detector is definitely following the string. But the G string on a standard
    /// guitar is **196 Hz**. 392 Hz is G4, exactly an octave above the G3 the player
    /// is tuning, and it is a real string on a ukulele and on nothing on a guitar.
    ///
    /// Those two readings need very different fixes, and a frequency alone cannot
    /// separate them, so this asks the spectrum directly: if the recording carries
    /// energy at 196 Hz, the detector skipped a fundamental that was there to be
    /// found. If it does not, the string really is sounding at 392 and nothing is
    /// wrong with the estimate.
    @Test("recording: is the G string being reported an octave up?")
    func recordedOctaveQuestion() {
        guard let wav = AudioTestHelpers.loadWav(name: "tuning_g") else {
            Issue.record("tuning_g.wav fixture missing")
            return
        }
        let rate = wav.sampleRate
        let g3 = 195.9977
        let g4 = 391.9954

        // Loudest 4096-sample windows, so the spectrum is taken where the player was
        // definitely sounding something rather than over room tone.
        let windowSize = 4096
        let hop = windowSize / 2
        var peaks: [(t: Double, hz: Double, score: Double)] = []
        for start in stride(from: 0, through: wav.samples.count - windowSize, by: hop) {
            let slice = Array(wav.samples[start..<(start + windowSize)])
            var sumSq = 0.0
            for s in slice { sumSq += Double(s * s) }
            let rms = sqrt(sumSq / Double(slice.count))
            guard rms > 0.005 else { continue }
            guard let analysis = SpectralPitchScorer().analyzeAudio(samples: slice, sampleRate: rate),
                  let best = analysis.candidates.max(by: { $0.score < $1.score })
            else { continue }
            peaks.append((Double(start) / rate, best.frequency, best.score))
        }
        guard !peaks.isEmpty else {
            Issue.record("no loud windows found in tuning_g")
            return
        }

        let medianHz = peaks.map(\.hz).sorted()[peaks.count / 2]
        print(String(format: "@@ OCTAVE loud windows=%d  median detected=%.2f Hz  (G3=%.2f, G4=%.2f)",
                     peaks.count, medianHz, g3, g4))
        print("@@ OCTAVE detected Hz per window: \(peaks.map { String(format: "%.1f", $0.hz) }.joined(separator: " "))")

        // Direct spectral energy at each octave, over the loudest window. This is the
        // measurement that decides it: it does not ask the detector what it thinks, it
        // asks the audio what is in it.
        let loudest = peaks.max { $0.score < $1.score }!
        let start = Int(loudest.t * rate)
        let slice = Array(wav.samples[start..<min(wav.samples.count, start + windowSize)])
        print("@@ OCTAVE probing the loudest window at t=\(String(format: "%.3f", loudest.t))s")
        for (label, hz) in [("G3 fundamental", g3), ("G3 2nd harmonic", g3 * 2),
                            ("G4 fundamental", g4), ("G4 2nd harmonic", g4 * 2),
                            ("G3 3rd harmonic", g3 * 3)] {
            let power = HannProjection.normalizedPower(samples: slice, frequency: hz, sampleRate: rate)
            print(String(format: "@@ OCTAVE   %-16@ %8.2f Hz  power=%.6f", label as NSString, hz, power))
        }

        // What the app would show for each hypothesis, in Auto mode on a guitar.
        for (label, hz) in [("as G3", g3), ("as G4", g4)] {
            let config = Self.config()
            let resolved = Tuning.resolve(
                instrument: .guitar, tuningId: "standard", customMidi: [40, 45, 50, 55, 59, 64],
                mode: .auto, a4: 440, precision: false, guided: false, selectedString: 0
            )
            var closest = 0.0
            for (index, target) in resolved.targets.enumerated() {
                let distance = abs(1200.0 * log2(hz / target.frequency))
                if index == 0 || distance < closest { closest = distance; _ = target }
            }
            let nearest = resolved.targets.min {
                abs(1200.0 * log2(hz / $0.frequency)) < abs(1200.0 * log2(hz / $1.frequency))
            }!
            let distance = abs(1200.0 * log2(hz / nearest.frequency))
            print(String(format: "@@ AUTO %@: nearest guitar string is %@ at %.1f Hz, %.0f cents away -> %@",
                         label as NSString, nearest.note as NSString, nearest.frequency, distance,
                         (distance <= TunerConstants.maxDetuningCents ? "accepted" : "REJECTED (targetMismatch)") as NSString))
        }
    }

    /// **The recording's diagnosis, as an assertion.**
    ///
    /// The player's own audio, replayed through the real pipeline, says:
    ///
    /// - The string being tuned sounds at ~384 Hz, and that pitch **tracks the peg
    ///   turn** across the session — the detected frequency rises and falls with the
    ///   player's hand. The estimator is not stuck; it follows the string correctly.
    /// - There is **no energy at 196 Hz** in the loudest window (power 0.000000),
    ///   while 392 Hz carries 0.092. So the string really is sounding near 392 and
    ///   the detector is not skipping a fundamental that was there to be found.
    /// - 392 Hz is 300 cents from the nearest guitar string (E4, 329.6 Hz), which is
    ///   past the 200-cent Auto gate, so **every frame of this recording is rejected
    ///   as `targetMismatch`** and the display never gets a value to show.
    ///
    /// So the arrow is not failing to react to the peg. There is no reading for it to
    /// react with: 88% of frames are dark and the 12% that reach a decision are all
    /// rejected as off-target.
    ///
    /// The unresolved part is the octave. Either the player is on a **ukulele** —
    /// whose high-G string *is* 392 Hz, and `Presets.ukulele.high-g` = [67, 60, 64, 69]
    /// with 67 = G4 — in which case the app is being run with the wrong instrument
    /// selected, or the guitar's G is being detected an octave high, which is a
    /// detection bug. The audio alone cannot settle that, and the two need different
    /// fixes, so this asserts only what the audio proves.
    @Test("recording: what the pipeline does with the player's tuning session")
    func recordedSessionDiagnosis() {
        guard let wav = AudioTestHelpers.loadWav(name: "tuning_g") else {
            Issue.record("tuning_g.wav fixture missing")
            return
        }
        let rate = wav.sampleRate
        let (frames, _) = AudioTestHelpers.replayTrace(
            samples: wav.samples, sampleRate: rate, config: Self.config()
        )

        // Claim 1: the estimator followed the peg. A stuck detector would report one
        // frequency; a following one spreads across the session's tuning range.
        let heard = frames.filter { $0.rawFrequency > 0 }.map(\.rawFrequency)
        let spread = (heard.max() ?? 0) - (heard.min() ?? 0)
        print(String(format: "@@ DIAG heard %d frames, %.1f..%.1f Hz (spread %.1f Hz = %.0f cents)",
                     heard.count, heard.min() ?? 0, heard.max() ?? 0, spread,
                     1200.0 * log2((heard.max() ?? 1) / (heard.min() ?? 1))))
        #expect(spread > 5.0, "estimator reported a single fixed frequency; it is not following the peg")

        // Claim 2: there is no energy at the guitar G3, so this is not a skipped
        // fundamental. Measured on the loudest window, at the two octaves.
        let windowSize = 4096
        var bestRMS = 0.0
        var bestStart = 0
        for start in stride(from: 0, through: wav.samples.count - windowSize, by: windowSize / 2) {
            var sumSq = 0.0
            for s in wav.samples[start..<(start + windowSize)] { sumSq += Double(s * s) }
            let rms = sqrt(sumSq / Double(windowSize))
            if rms > bestRMS { bestRMS = rms; bestStart = start }
        }
        let slice = Array(wav.samples[bestStart..<(bestStart + windowSize)])
        let atG3 = HannProjection.normalizedPower(samples: slice, frequency: 195.9977, sampleRate: rate)
        let atG4 = HannProjection.normalizedPower(samples: slice, frequency: 391.9954, sampleRate: rate)
        print(String(format: "@@ DIAG loudest window: power@196Hz=%.6f  power@392Hz=%.6f  ratio=%.1fx",
                     atG3, atG4, atG3 > 0 ? atG4 / atG3 : .infinity))
        #expect(
            atG4 > 50 * atG3,
            "unexpected: substantial energy at 196 Hz, so the octave reading needs re-examining"
        )

        // Claim 3: the symptom. Auto mode on a guitar accepts almost none of this
        // recording, so the arrow has nothing to follow.
        //
        // Measured against the frames where the pipeline had a pitch to judge rather
        // than every frame: 858 of 1290 are `gate` rejections, which say the room was
        // silent, not that the string was rejected. Claiming "88% rejected" would be
        // true of the frame count and misleading about the fault, so the honest
        // denominator is the frames that reached a decision.
        let dark = frames.filter { $0.reading == nil }.count
        let decided = frames.filter { $0.rejection != nil && $0.rejection != "gate" }
        let targetMismatch = decided.filter { $0.rejection == "targetMismatch" }.count
        print(String(format: "@@ DIAG frames=%d  dark=%.0f%%  gate=%d  decided=%d  of which targetMismatch=%.0f%%",
                     frames.count, 100.0 * Double(dark) / Double(frames.count),
                     frames.filter { $0.rejection == "gate" }.count,
                     decided.count,
                     decided.isEmpty ? 0 : 100.0 * Double(targetMismatch) / Double(decided.count)))
        #expect(
            decided.isEmpty == false && Double(targetMismatch) > 0.8 * Double(decided.count),
            "expected the decided frames of this recording to be dominated by target-mismatch rejections in Auto mode"
        )
    }

    /// The player's actual instrument, against the player's actual recording.
    ///
    /// The "octave error" is resolved: the player has a **ukulele**, and
    /// `Presets.ukulele.high-g` is `[67, 60, 64, 69]` — 67 is **G4 at 392 Hz**. So the
    /// 384 Hz the detector heard was the high-G string being tracked correctly, and
    /// the app was rejecting it only because the default `TunerConfig` is a **guitar**,
    /// whose nearest string (E4, 329.6 Hz) is 300 cents away and so fails the Auto gate.
    ///
    /// This is the regression test for that: the same recording, the same pipeline, the
    /// instrument set correctly. It is here rather than deleted because a config
    /// default that silently assumes an instrument the player does not have is a real
    /// hazard, and a recording that proves it is worth keeping.
    @Test("recording: tuning_g under a ukulele tuning")
    func recordedUkuleleSession() {
        guard let wav = AudioTestHelpers.loadWav(name: "tuning_g") else {
            Issue.record("tuning_g.wav fixture missing")
            return
        }
        let rate = wav.sampleRate

        let ukulele = TunerConfig(
            instrument: .ukulele, tuningId: "high-g",
            customMidi: [67, 60, 64, 69], a4: 440,
            mode: .auto, selectedString: 0, precision: false, guided: false
        )
        let targets = Tuning.resolve(
            instrument: .ukulele, tuningId: "high-g", customMidi: [67, 60, 64, 69],
            mode: .auto, a4: 440, precision: false, guided: false, selectedString: 0
        ).targets
        print("@@ UKE targets: \(targets.map { "\($0.note)=\(String(format: "%.1f", $0.frequency))Hz" })")

        let (frames, tracker) = AudioTestHelpers.replayTrace(
            samples: wav.samples, sampleRate: rate, config: ukulele
        )

        let dark = frames.filter { $0.reading == nil }.count
        let fresh = frames.filter { frame in
            frame.reading.map { AudioTestHelpers.wasMeasuredThisFrame($0) } ?? false
        }
        let decided = frames.filter { $0.rejection != nil && $0.rejection != "gate" }
        let targetMismatch = decided.filter { $0.rejection == "targetMismatch" }.count
        print(String(format: "@@ UKE frames=%d  fresh=%d (%.0f%%)  dark=%.0f%%  decided=%d  targetMismatch=%d (%.0f%% of decided)",
                     frames.count, fresh.count, 100.0 * Double(fresh.count) / Double(frames.count),
                     100.0 * Double(dark) / Double(frames.count), decided.count, targetMismatch,
                     decided.isEmpty ? 0 : 100.0 * Double(targetMismatch) / Double(decided.count)))
        print("@@ UKE final tracker state: \(tracker.feedbackState)")

        // The per-frame trace, so the peg turns are visible as movement.
        print("-- t / heardHz / centsFromTarget / state --")
        for frame in frames {
            let t = frame.captureEndSeconds
            let r = frame.reading
            let heard = frame.rawFrequency
            let cents = r?.cents ?? Double.nan
            print([
                String(format: "%6.3f", t),
                String(format: "%8.2f", heard),
                String(format: "%8.2f", cents),
                "\(frame.displayState) \((frame.rejection ?? "-"))",
            ].joined(separator: " "))
        }

        // With the instrument set correctly the tuner actually acquires the note and
        // follows the peg, instead of rejecting every frame as off-target.
        #expect(
            Double(targetMismatch) < 0.5 * Double(decided.count),
            "ukulele config should not be dominated by target-mismatch rejections; \(targetMismatch)/\(decided.count)"
        )
        #expect(
            fresh.count > 50,
            "expected the ukulele high-G string to be acquired across the session, got \(fresh.count) fresh frames"
        )
    }

    /// **"It moves at the beginning, then stops detecting."**
    ///
    /// That is a claim about the *level* gate over the life of the session, so this
    /// replays the recording one frame at a time and records, per frame, the level the
    /// detector measured against the gate it was actually given. Replaying through
    /// `replayTrace` would not answer it: that returns the tracker once at the end, so
    /// the gate — which is recomputed from a *moving* ambient floor on every frame —
    /// would only be visible in its final state.
    ///
    /// The question is which of two very different things is happening:
    ///
    /// - the room got quiet and the string genuinely fell below the gate, in which
    ///   case the detector is being honest and the audio is the limit; or
    /// - the gate **rose to meet the decaying note** and cut off a string that was
    ///   still sounding well above the room. The tracker's ambient floor is adaptive,
    ///   so this is possible in principle, and it would be a bug: the floor is
    ///   supposed to estimate the room, and a decaying note is not the room.
    @Test("recording: why detection stops — level gate vs the room")
    func recordedDetectionDecay() {
        guard let wav = AudioTestHelpers.loadWav(name: "tuning_g") else {
            Issue.record("tuning_g.wav fixture missing")
            return
        }
        let rate = wav.sampleRate
        let config = TunerConfig(
            instrument: .ukulele, tuningId: "high-g", customMidi: [67, 60, 64, 69],
            a4: 440, mode: .auto, selectedString: 0, precision: false, guided: false
        )
        let targets = Tuning.resolve(
            instrument: .ukulele, tuningId: "high-g", customMidi: [67, 60, 64, 69],
            mode: .auto, a4: 440, precision: false, guided: false, selectedString: 0
        ).targets
        let tracker = PitchTracker()
        tracker.reset(targetCount: targets.count)
        let session = TunerAnalysisSession(config: config, targets: targets, tracker: tracker)

        let hop = AudioTestHelpers.productionHopSamples
        let windowLength = Resampler.requiredInputSamples(for: rate)
        var sequence: UInt64 = 0
        var rows: [(t: Double, rms: Double, gate: Double, floor: Double, state: String, reject: String?)] = []

        for endSample in stride(from: hop, through: wav.samples.count, by: hop) {
            sequence &+= 1
            let start = max(0, endSample - windowLength)
            let frame = AnalysisFrame(
                samples: Array(wav.samples[start..<endSample]), sampleRate: rate,
                captureEndSeconds: Double(endSample) / rate,
                sequence: sequence, generation: session.generation, callbackFrameCount: hop
            )
            guard let snapshot = session.processFrameSync(frame) else { continue }
            let reject = AudioTestHelpers.classifyRejection(
                pitchResult: snapshot.pitchResult,
                noiseGate: tracker.recommendedNoiseGate(isSustaining: false),
                reading: snapshot.reading,
                feedbackState: snapshot.feedbackState
            )
            rows.append((
                Double(endSample) / rate,
                snapshot.pitchResult.amplitudeRMS,
                Double(tracker.recommendedNoiseGate(isSustaining: false)),
                tracker.ambientFloor,
                snapshot.feedbackState.rawValue,
                reject
            ))
        }

        // Per-frame trace, so the moment detection stops is visible.
        print("--    t      rms     gate    floor  state    reject --")
        for row in rows {
            print([
                String(format: "%7.3f", row.t),
                String(format: "%9.6f", row.rms),
                String(format: "%9.6f", row.gate),
                String(format: "%9.6f", row.floor),
                "\(row.state) \((row.reject ?? "-"))",
            ].joined(separator: " "))
        }

        // Split the session into the part where the needle is alive and the part after
        // it dies, and compare the levels. If the level in the dead part is a real
        // multiple of the gate, the gate is not what stopped it.
        let peakRMS = rows.map(\.rms).max() ?? 0
        let firstPluckEnd = rows.first { $0.rms > 0.5 * peakRMS }?.t ?? 0
        let alive = rows.filter { $0.t <= firstPluckEnd + 1.0 }
        let afterwards = rows.filter { $0.t > firstPluckEnd + 1.0 }

        func median(_ values: [Double]) -> Double {
            guard !values.isEmpty else { return .nan }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        print(String(format: "@@ DECAY peak rms=%.6f  alive frames=%d  after frames=%d",
                     peakRMS, alive.count, afterwards.count))
        print(String(format: "@@ DECAY alive:   median rms=%.6f  median gate=%.6f  median floor=%.6f",
                     median(alive.map(\.rms)), median(alive.map(\.gate)), median(alive.map(\.floor))))
        print(String(format: "@@ DECAY after:   median rms=%.6f  median gate=%.6f  median floor=%.6f",
                     median(afterwards.map(\.rms)), median(afterwards.map(\.gate)), median(afterwards.map(\.floor))))

        // How often was the level gate the reason nothing was shown?
        let gated = rows.filter { $0.reject == "gate" }
        print(String(format: "@@ DECAY gated=%d of %d (%.0f%%)",
                     gated.count, rows.count, 100.0 * Double(gated.count) / Double(rows.count)))

        // The discriminator: in the frames the gate rejected, was the level far enough
        // below the gate that the gate was the honest answer? A frame rejected while
        // sitting at a substantial fraction of the gate is a gate that is too high for
        // the signal in front of it.
        let closeCalls = gated.filter { $0.rms > 0.5 * $0.gate }
        print(String(format: "@@ DECAY gated but at >50%% of the gate: %d frames", closeCalls.count))
        if !closeCalls.isEmpty {
            let worst = closeCalls.max { $0.rms / $0.gate < $1.rms / $1.gate }!
            print(String(format: "@@ DECAY   worst: t=%.3f rms=%.6f gate=%.6f (%.0f%% of gate) floor=%.6f",
                         worst.t, worst.rms, worst.gate, 100 * worst.rms / worst.gate, worst.floor))
        }
    }

    /// Whether the learned ambient floor is the *room*, or the string's own decay.
    ///
    /// The tracker's floor starts at 0.0002 and adapts upward with a 0.05 coefficient,
    /// guarded so that a decaying note only feeds it when nothing is on the display.
    /// That guard is the whole safety story, so it is worth measuring directly: this
    /// compares the floor the tracker ended up with against the **actual room tone** in
    /// the quietest part of the recording, which is a property of the audio and needs
    /// no tracker at all.
    ///
    /// A floor that has grown well above the real room is a floor that has learned the
    /// wrong thing, and it makes the gate too high for a note that is still sounding.
    @Test("recording: did the ambient floor learn the room, or the decaying string?")
    func recordedAmbientFloor() {
        guard let wav = AudioTestHelpers.loadWav(name: "tuning_g") else {
            Issue.record("tuning_g.wav fixture missing")
            return
        }
        let rate = wav.sampleRate
        let window = Int(rate * 0.09)   // the same 90 ms the tracker measures over

        // The room: the quietest 90 ms windows in the whole recording. If the floor has
        // learned the room, this is what it should have converged to.
        var windowRMS: [(t: Double, rms: Double)] = []
        for start in stride(from: 0, through: wav.samples.count - window, by: window / 2) {
            var sumSq = 0.0
            for s in wav.samples[start..<(start + window)] { sumSq += Double(s * s) }
            windowRMS.append((Double(start) / rate, sqrt(sumSq / Double(window))))
        }
        let sortedRMS = windowRMS.map(\.rms).sorted()
        let quietest = sortedRMS[sortedRMS.count / 20]      // 5th percentile: the room
        let median = sortedRMS[sortedRMS.count / 2]
        let p95 = sortedRMS[sortedRMS.count * 95 / 100]
        print(String(format: "@@ FLOOR room: 5th pct=%.6f  median=%.6f  p95=%.6f  (90 ms windows)",
                     quietest, median, p95))
        let quietestWindow = windowRMS.min { $0.rms < $1.rms }!
        print(String(format: "@@ FLOOR quietest window is at t=%.3fs, rms=%.6f",
                     quietestWindow.t, quietestWindow.rms))

        // What the tracker converged to, from the replay above: 0.002267.
        // Recomputed here rather than hardcoded so this stays a measurement.
        let config = TunerConfig(
            instrument: .ukulele, tuningId: "high-g", customMidi: [67, 60, 64, 69],
            a4: 440, mode: .auto, selectedString: 0, precision: false, guided: false
        )
        let targets = Tuning.resolve(
            instrument: .ukulele, tuningId: "high-g", customMidi: [67, 60, 64, 69],
            mode: .auto, a4: 440, precision: false, guided: false, selectedString: 0
        ).targets
        let tracker = PitchTracker()
        tracker.reset(targetCount: targets.count)
        let session = TunerAnalysisSession(config: config, targets: targets, tracker: tracker)
        let hop = AudioTestHelpers.productionHopSamples
        let windowLength = Resampler.requiredInputSamples(for: rate)
        var sequence: UInt64 = 0
        var floors: [Double] = []
        for endSample in stride(from: hop, through: wav.samples.count, by: hop) {
            sequence &+= 1
            let frame = AnalysisFrame(
                samples: Array(wav.samples[max(0, endSample - windowLength)..<endSample]),
                sampleRate: rate, captureEndSeconds: Double(endSample) / rate,
                sequence: sequence, generation: session.generation, callbackFrameCount: hop
            )
            _ = session.processFrameSync(frame)
            floors.append(tracker.ambientFloor)
        }
        let learned = floors.last ?? 0
        let initialFloor = PitchTracker.initialAmbientFloor
        print(String(format: "@@ FLOOR tracker: start=%.6f  end=%.6f  (grew %.1fx)",
                     initialFloor, learned, learned / initialFloor))
        print(String(format: "@@ FLOOR learned floor is %.1fx the recording's actual room tone (5th pct)",
                     learned / max(quietest, 1e-9)))

        // How many windows of the recording sit above the learned floor but below the
        // gate it produces? Those are the frames where a sounding string was silenced
        // by a floor that had risen past the room.
        let gate = Double(tracker.recommendedNoiseGate(isSustaining: false))
        let silenced = windowRMS.filter { $0.rms > learned && $0.rms < gate }
        print(String(format: "@@ FLOOR windows above the learned floor but under the %.6f gate: %d of %d",
                     gate, silenced.count, windowRMS.count))
        if !silenced.isEmpty {
            print(String(format: "@@ FLOOR   e.g. t=%.3f rms=%.6f (%.0f%% of the gate)",
                         silenced[silenced.count / 2].t, silenced[silenced.count / 2].rms,
                         100 * silenced[silenced.count / 2].rms / gate))
        }
    }

    /// The decision table for the floor, on the player's own recording.
    ///
    /// `PitchTracker` gates on `max(0.00015, ambientFloor * 1.4)`, and the floor adapts
    /// with a 0.05 coefficient toward any non-foreground audio seen while **nothing is
    /// on the display**. That guard is real, but it has a gap: a held reading expires
    /// after `readingHoldDuration` (1.0 s), and from that moment the decaying string
    /// *is* the only thing feeding the floor. The floor climbs, the gate climbs with
    /// it, and the decay is silenced earlier than it would have been — which shows the
    /// player as "it detected for a second and then stopped".
    ///
    /// Measured on `tuning_g`: the floor ends at 0.000511 while the recording's own
    /// quietest windows sit at 0.000194. So the floor converged to 2.6x the room it
    /// was supposed to be estimating.
    ///
    /// This sweeps the floor against the recording's own level distribution, so the
    /// choice is made on how much of the player's session each value keeps audible.
    @Test("recording: what the floor is costing, measured against the audio")
    func recordedFloorDecisionTable() {
        guard let wav = AudioTestHelpers.loadWav(name: "tuning_g") else {
            Issue.record("tuning_g.wav fixture missing")
            return
        }
        let rate = wav.sampleRate
        let window = Int(rate * 0.09)

        var windowRMS: [Double] = []
        for start in stride(from: 0, through: wav.samples.count - window, by: window / 2) {
            var sumSq = 0.0
            for s in wav.samples[start..<(start + window)] { sumSq += Double(s * s) }
            windowRMS.append(sqrt(sumSq / Double(window)))
        }
        let sorted = windowRMS.sorted()
        let room = sorted[sorted.count / 20]     // 5th percentile = the room

        // The floor the tracker actually converged to, re-measured rather than quoted.
        let config = TunerConfig(
            instrument: .ukulele, tuningId: "high-g", customMidi: [67, 60, 64, 69],
            a4: 440, mode: .auto, selectedString: 0, precision: false, guided: false
        )
        let targets = Tuning.resolve(
            instrument: .ukulele, tuningId: "high-g", customMidi: [67, 60, 64, 69],
            mode: .auto, a4: 440, precision: false, guided: false, selectedString: 0
        ).targets
        let tracker = PitchTracker()
        tracker.reset(targetCount: targets.count)
        let session = TunerAnalysisSession(config: config, targets: targets, tracker: tracker)
        let hop = AudioTestHelpers.productionHopSamples
        let windowLength = Resampler.requiredInputSamples(for: rate)
        var sequence: UInt64 = 0
        for endSample in stride(from: hop, through: wav.samples.count, by: hop) {
            sequence &+= 1
            _ = session.processFrameSync(AnalysisFrame(
                samples: Array(wav.samples[max(0, endSample - windowLength)..<endSample]),
                sampleRate: rate, captureEndSeconds: Double(endSample) / rate,
                sequence: sequence, generation: session.generation, callbackFrameCount: hop
            ))
        }
        let learned = tracker.ambientFloor

        print(String(format: "@@ TABLE room=%.6f  learned floor=%.6f  windows=%d", room, learned, windowRMS.count))
        print("@@ TABLE  floor      gate      windows audible   vs learned")
        for candidate in [PitchTracker.initialAmbientFloor, room, learned, 0.001, 0.002] {
            let gate = max(0.00015, candidate * 1.4)
            let audible = windowRMS.filter { $0 >= gate }.count
            print(String(format: "@@ TABLE  %.6f  %.6f  %4d (%.0f%%)      %+.0f%%",
                         candidate, gate, audible,
                         100.0 * Double(audible) / Double(windowRMS.count),
                         100.0 * (Double(audible) / Double(windowRMS.count) - 1.0)))
        }

        // The specific cost of the learned floor: windows the room floor would keep and
        // the learned one silences.
        let gateAtRoom = max(0.00015, room * 1.4)
        let gateAtLearned = max(0.00015, learned * 1.4)
        let lostToTheFloor = windowRMS.filter { $0 >= gateAtRoom && $0 < gateAtLearned }
        print(String(format: "@@ TABLE the learned floor silences %d windows the room floor would keep audible",
                     lostToTheFloor.count))
        if !lostToTheFloor.isEmpty {
            let loudest = lostToTheFloor.max { $0 < $1 }!
            print(String(format: "@@ TABLE   loudest silenced: rms=%.6f (%.0f%% of the learned gate)",
                         loudest, 100 * loudest / gateAtLearned))
        }
    }

    /// How much of the player's string the display actually covers.
    ///
    /// This is the symptom stated as a measurement: for each pluck, how long the
    /// string stays **audible** — above the room, judged by the recording's own
    /// quietest windows — compared with how long the display kept a **fresh** reading
    /// for it. The difference is time the player could hear the string and the tuner
    /// had nothing to say.
    ///
    /// Ground truth for "audible" is the audio, not the tracker: the 5th-percentile
    /// 90 ms window of this recording is 0.000194, which is the room, so a window
    /// above roughly twice that carries the string. The player says they can hear it
    /// for about 3 seconds, and this asks whether the display agrees.
    @Test("recording: audible time vs displayed time, per pluck")
    func recordedCoverageVsAudibleTime() {
        guard let wav = AudioTestHelpers.loadWav(name: "tuning_g") else {
            Issue.record("tuning_g.wav fixture missing")
            return
        }
        let rate = wav.sampleRate
        let config = TunerConfig(
            instrument: .ukulele, tuningId: "high-g", customMidi: [67, 60, 64, 69],
            a4: 440, mode: .auto, selectedString: 0, precision: false, guided: false
        )
        let targets = Tuning.resolve(
            instrument: .ukulele, tuningId: "high-g", customMidi: [67, 60, 64, 69],
            mode: .auto, a4: 440, precision: false, guided: false, selectedString: 0
        ).targets
        let tracker = PitchTracker()
        tracker.reset(targetCount: targets.count)
        let session = TunerAnalysisSession(config: config, targets: targets, tracker: tracker)

        let hop = AudioTestHelpers.productionHopSamples
        let windowLength = Resampler.requiredInputSamples(for: rate)
        var sequence: UInt64 = 0
        var rows: [(t: Double, rms: Double, fresh: Bool, anyReading: Bool, floor: Double, reject: String?)] = []
        for endSample in stride(from: hop, through: wav.samples.count, by: hop) {
            sequence &+= 1
            let frame = AnalysisFrame(
                samples: Array(wav.samples[max(0, endSample - windowLength)..<endSample]),
                sampleRate: rate, captureEndSeconds: Double(endSample) / rate,
                sequence: sequence, generation: session.generation, callbackFrameCount: hop
            )
            guard let snapshot = session.processFrameSync(frame) else { continue }
            let reject = AudioTestHelpers.classifyRejection(
                pitchResult: snapshot.pitchResult,
                noiseGate: tracker.recommendedNoiseGate(isSustaining: false),
                reading: snapshot.reading, feedbackState: snapshot.feedbackState
            )
            let reading = snapshot.reading
            rows.append((
                Double(endSample) / rate,
                snapshot.pitchResult.amplitudeRMS,
                reading.map { AudioTestHelpers.wasMeasuredThisFrame($0) } ?? false,
                reading != nil,
                tracker.ambientFloor,
                reject
            ))
        }

        // The room, from the recording itself.
        let levelWindow = Int(rate * 0.09)
        var levelRMS: [Double] = []
        for start in stride(from: 0, through: wav.samples.count - levelWindow, by: levelWindow / 2) {
            var sumSq = 0.0
            for s in wav.samples[start..<(start + levelWindow)] { sumSq += Double(s * s) }
            levelRMS.append(sqrt(sumSq / Double(levelWindow)))
        }
        let sortedLevels = levelRMS.sorted()
        let room = sortedLevels[sortedLevels.count / 20]
        let audibleThreshold = room * 2.0
        print(String(format: "@@ COVER room=%.6f  audible above %.6f", room, audibleThreshold))

        // Pluck onsets: the string's level rising sharply out of the room.
        var onsets: [Double] = []
        for index in 1..<rows.count {
            let previous = rows[index - 1].rms
            let current = rows[index].rms
            if current > audibleThreshold, current > previous * 2.5, rows[index].t - (onsets.last ?? -9) > 0.4 {
                onsets.append(rows[index].t)
            }
        }
        print("@@ COVER \(onsets.count) pluck onsets at: \(onsets.map { String(format: "%.2f", $0) }.joined(separator: " "))")

        var audibleTotal = 0.0
        var freshTotal = 0.0
        var anyTotal = 0.0
        var lost = 0.0
        for (index, onset) in onsets.enumerated() {
            let end = index + 1 < onsets.count ? onsets[index + 1] : rows.last!.t
            let span = rows.filter { $0.t >= onset && $0.t < end }
            guard !span.isEmpty else { continue }
            let audibleFrames = span.filter { $0.rms >= audibleThreshold }.count
            let freshFrames = span.filter(\.fresh).count
            let anyFrames = span.filter(\.anyReading).count
            let frameSeconds = Double(hop) / rate
            let audible = Double(audibleFrames) * frameSeconds
            let fresh = Double(freshFrames) * frameSeconds
            let any = Double(anyFrames) * frameSeconds
            audibleTotal += audible
            freshTotal += fresh
            anyTotal += any
            lost += max(0, audible - fresh)
            print(String(format: "@@ COVER   t=%5.2f  audible=%5.2fs  fresh=%5.2fs  anyReading=%5.2fs  lost=%5.2fs",
                         onset, audible, fresh, any, max(0, audible - fresh)))
        }

        print(String(format: "@@ COVER TOTAL audible=%.2fs  fresh=%.2fs  anyReading=%.2fs  lost=%.2fs (%.0f%% of audible)",
                     audibleTotal, freshTotal, anyTotal, lost,
                     audibleTotal > 0 ? 100 * lost / audibleTotal : 0))
    }

    /// A **bright, frozen** needle is not the same failure as a dim one, and the
    /// difference is decided in the presentation layer.
    ///
    /// `TunerPresentation.holdOpacity` returns 1.0 for any reading whose
    /// `freshness == .fresh` and only fades a `.held` one. So a needle that is
    /// **dim** means the tracker published a Held reading — the display is admitting
    /// the sound stopped. A needle that is **bright but not moving** means something
    /// published a reading claiming `freshness: .fresh` for a frame in which no new
    /// measurement was made.
    ///
    /// There is exactly one path that does that: `PitchTracker.pinnedReading`, reached
    /// when `mayChangeDisplay` refuses to let the display weaken. It copies the
    /// previous reading field for field, including `freshness: .fresh`, and the
    /// presentation layer has no way to tell it apart from a real measurement —
    /// `AudioTestHelpers.wasMeasuredThisFrame` exists for exactly that reason.
    ///
    /// So the two symptoms are two different subsystems, and the player's report of
    /// "sometimes dim, sometimes frozen" is two bugs, not one intermittent one. This
    /// attributes every frame of the recording to one or the other.
    @Test("recording: dim-needle frames vs bright-frozen frames")
    func recordedFrozenVersusDim() {
        guard let wav = AudioTestHelpers.loadWav(name: "tuning_g") else {
            Issue.record("tuning_g.wav fixture missing")
            return
        }
        let rate = wav.sampleRate
        let config = TunerConfig(
            instrument: .ukulele, tuningId: "high-g", customMidi: [67, 60, 64, 69],
            a4: 440, mode: .auto, selectedString: 0, precision: false, guided: false
        )
        let targets = Tuning.resolve(
            instrument: .ukulele, tuningId: "high-g", customMidi: [67, 60, 64, 69],
            mode: .auto, a4: 440, precision: false, guided: false, selectedString: 0
        ).targets
        let tracker = PitchTracker()
        tracker.reset(targetCount: targets.count)
        let session = TunerAnalysisSession(config: config, targets: targets, tracker: tracker)

        let hop = AudioTestHelpers.productionHopSamples
        let windowLength = Resampler.requiredInputSamples(for: rate)
        var sequence: UInt64 = 0
        var rows: [(t: Double, rms: Double, gate: Double, kind: String, reject: String?, cents: Double)] = []
        for endSample in stride(from: hop, through: wav.samples.count, by: hop) {
            sequence &+= 1
            let frame = AnalysisFrame(
                samples: Array(wav.samples[max(0, endSample - windowLength)..<endSample]),
                sampleRate: rate, captureEndSeconds: Double(endSample) / rate,
                sequence: sequence, generation: session.generation, callbackFrameCount: hop
            )
            guard let snapshot = session.processFrameSync(frame) else { continue }
            let reject = AudioTestHelpers.classifyRejection(
                pitchResult: snapshot.pitchResult,
                noiseGate: tracker.recommendedNoiseGate(isSustaining: false),
                reading: snapshot.reading, feedbackState: snapshot.feedbackState
            )

            // The attribution. `wasMeasuredThisFrame` is the only thing that separates a
            // republished reading from a new one; `freshness` cannot, by design.
            let kind: String
            switch snapshot.reading {
            case nil:
                kind = "dark"
            case .some(let reading):
                if AudioTestHelpers.wasMeasuredThisFrame(reading) {
                    kind = "measured"
                } else if reading.freshness == .held {
                    kind = "held(dim)"
                } else {
                    kind = "PINNED(bright-frozen)"
                }
            }
            rows.append((
                Double(endSample) / rate, snapshot.pitchResult.amplitudeRMS,
                Double(tracker.recommendedNoiseGate(isSustaining: false)),
                kind, reject, snapshot.reading?.cents ?? Double.nan
            ))
        }

        var counts: [String: Int] = [:]
        for row in rows { counts[row.kind, default: 0] += 1 }
        print("@@ PIN attribution over \(rows.count) frames:")
        for (kind, count) in counts.sorted(by: { $0.value > $1.value }) {
            print(String(format: "@@ PIN   %-22@ %4d (%.0f%%)", kind as NSString, count,
                         100.0 * Double(count) / Double(rows.count)))
        }

        // Of the frames where the needle is bright and not moving, why is it there?
        // Grouped by the rejection the detector reported on that same frame: that is
        // the cause of the *pin*, not a guess about it.
        let pinned = rows.filter { $0.kind == "PINNED(bright-frozen)" }
        var pinCauses: [String: Int] = [:]
        for row in pinned { pinCauses[row.reject ?? "-", default: 0] += 1 }
        print("@@ PIN bright-frozen frames, by what the detector said on the same frame:")
        for (cause, count) in pinCauses.sorted(by: { $0.value > $1.value }) {
            print(String(format: "@@ PIN   %-22@ %4d", cause as NSString, count))
        }

        // And the level at which it freezes: is the string still well above the room?
        let pinnedAudible = pinned.filter { $0.rms > 0.000387 }
        print(String(format: "@@ PIN %d of %d pinned frames are at a level where the string is still audible (rms>0.000387)",
                     pinnedAudible.count, pinned.count))

        // The runs, so a frozen needle's duration is visible rather than a count.
        print("-- bright-frozen runs (>=0.15s) --")
        var runStart: Double?
        var previousTime: Double = 0
        for row in rows {
            let isPinned = row.kind == "PINNED(bright-frozen)"
            if isPinned, runStart == nil { runStart = row.t }
            if !isPinned, let start = runStart {
                if row.t - start >= 0.15 {
                    print(String(format: "@@ PIN   %.3fs..%.3fs  (%.2fs frozen)",
                                 start, row.t, row.t - start))
                }
                runStart = nil
            }
            previousTime = row.t
        }
        if let start = runStart, previousTime - start >= 0.15 {
            print(String(format: "@@ PIN   %.3fs..%.3fs  (%.2fs frozen)", start, previousTime, previousTime - start))
        }

        // The two failure modes, stated as counts, so a future change can be judged
        // against this recording rather than against a feeling.
        #expect(
            pinned.count > 0,
            "expected some frames to republish a reading as fresh without measuring (the bright-frozen symptom)"
        )
        print(String(format: "@@ PIN SUMMARY measured=%d held=%d pinned=%d dark=%d",
                     counts["measured"] ?? 0, counts["held(dim)"] ?? 0,
                     counts["PINNED(bright-frozen)"] ?? 0, counts["dark"] ?? 0))
    }

    /// **Why some strings are worse than others.**
    ///
    /// The player reports that on their ukulele, G and C track the peg and E and A do
    /// not. That is a per-**String** difference, and nothing in the pipeline is
    /// obviously string-dependent — so the question is whether the geometry of the
    /// tuning is what differs.
    ///
    /// `Presets.ukulele.high-g` is `[67, 60, 64, 69]` = G4 392.0, C4 261.6, E4 329.6,
    /// A4 440.0. Sorted, the gaps between neighbours are:
    ///
    ///     C4 -> E4   400 cents
    ///     E4 -> G4   300 cents
    ///     G4 -> A4   200 cents   <- a whole tone
    ///
    /// And `TunerConstants.maxDetuningCents` is **200**. So a pitch sitting between any
    /// two strings is only accepted if it is within 200 cents of one, which means the
    /// band between C4 and E4 — exactly 400 apart — is right *on* the gate at its
    /// midpoint: half a cent either side of the ideal position decides whether the
    /// reading is accepted or dropped. That is a knife edge, and it moves as the string
    /// moves.
    ///
    /// This measures, per string, whether a peg turn stays on its own string and keeps
    /// producing fresh readings. The signal is synthesised at each string's real
    /// frequency and at the level measured from the player's own recording, so the
    /// levels are theirs even though the pitches are constructed.
    @Test("ukulele: per-string responsiveness across the tuning")
    func ukulelePerStringResponsiveness() {
        let rate = 44100.0
        // Levels taken from the player's recording: a pluck peaks around 0.28 RMS and
        // sits near 0.010 while it is still plainly audible.
        let pluckAmplitude = 0.28
        let audibleAmplitude = 0.010

        let strings: [(name: String, midi: Int)] = [
            ("G4", 67), ("C4", 60), ("E4", 64), ("A4", 69),
        ]
        let sorted = strings.sorted { $0.midi < $1.midi }
        print("@@ STRINGS ukulele high-g gaps:")
        for i in 1..<sorted.count {
            let lower = 440.0 * pow(2.0, Double(sorted[i - 1].midi - 69) / 12.0)
            let upper = 440.0 * pow(2.0, Double(sorted[i].midi - 69) / 12.0)
            print(String(format: "@@ STRINGS   %@ -> %@ = %.0f cents (gate is %.0f)",
                         sorted[i - 1].name as NSString, sorted[i].name as NSString,
                         1200.0 * log2(upper / lower), TunerConstants.maxDetuningCents))
        }

        struct StringResult {
            var name: String
            var wrongStringFrames = 0
            var darkFrames = 0
            var freshFrames = 0
            var ambiguousFrames = 0
            var distanceRange = (min: Double.greatestFiniteMagnitude, max: -Double.greatestFiniteMagnitude)
        }

        var results: [StringResult] = []
        for entry in strings {
            let targetHz = 440.0 * pow(2.0, Double(entry.midi - 69) / 12.0)
            var result = StringResult(name: entry.name, wrongStringFrames: 0, darkFrames: 0,
                                      freshFrames: 0, ambiguousFrames: 0, distanceRange: (.greatestFiniteMagnitude, -.greatestFiniteMagnitude))

            // A tuning gesture on this string: start 25 cents flat, four plucks, each
            // closer, ending in tune. Between plucks the note decays, as it does on a
            // real instrument — this is the shape that failed for the player.
            let pitchSteps: [Double] = [-25, -16, -9, -4, 0]
            for (index, cents) in pitchSteps.enumerated() {
                let samples = TuningResponsivenessHarness.glide(
                    referenceHz: targetHz, rate: rate, seconds: 3.0,
                    centsAt: { _ in cents },
                    decaySeconds: 1.8
                )
                // Scale to the measured pluck level.
                var peak = 0.0
                for s in samples { peak = max(peak, Double(abs(s))) }
                let scaled = peak > 0 ? samples.map { Float(Double($0) / peak * pluckAmplitude) } : samples

                let config = TunerConfig(
                    instrument: .ukulele, tuningId: "high-g", customMidi: [67, 60, 64, 69],
                    a4: 440, mode: .auto, selectedString: 0, precision: false, guided: false
                )
                let (frames, _) = AudioTestHelpers.replayTrace(
                    samples: scaled, sampleRate: rate, config: config
                )
                for frame in frames where frame.captureEndSeconds > 0.3 {
                    result.distanceRange.min = min(result.distanceRange.min, frame.rawFrequency)
                    result.distanceRange.max = max(result.distanceRange.max, frame.rawFrequency)
                    if frame.rejection == "ambiguous" || frame.rejection == "targetMismatch" {
                        result.ambiguousFrames += 1
                    }
                    guard let reading = frame.reading else {
                        result.darkFrames += 1
                        continue
                    }
                    if AudioTestHelpers.wasMeasuredThisFrame(reading) { result.freshFrames += 1 }
                    // Was the reading measured against *this* string?
                    if case .target(let target, _) = reading.aim,
                       abs(target.frequency - targetHz) > 0.5 {
                        result.wrongStringFrames += 1
                    }
                }
                _ = index
            }
            results.append(result)
        }

        print("@@ STRINGS per-string results over a -25 -> 0 tuning gesture:")
        for result in results {
            let judged = result.freshFrames + result.wrongStringFrames + result.darkFrames
            print(String(format: "@@ STRINGS   %@  fresh=%4d  aimedAtWrongString=%4d  dark=%4d  rejected=%4d  (%.0f%% of %d judged)",
                         result.name as NSString, result.freshFrames, result.wrongStringFrames,
                         result.darkFrames, result.ambiguousFrames,
                         judged > 0 ? 100.0 * Double(result.freshFrames) / Double(judged) : 0, judged))
        }

        // A string is only "responsive" if the readings come back and they are about
        // that string. A string that scores well on fresh frames but aims at its
        // neighbour would feel worse than one that is simply quiet.
        for result in results {
            print(String(format: "@@ STRINGS   %@ heard %.1f..%.1f Hz",
                         result.name as NSString,
                         result.distanceRange.min, result.distanceRange.max))
        }
    }

    @Test("diagnostic: 120-cent sweep over 6 s, auto mode")
    func sweepTrace() {
        let rate = 44100.0
        let samples = TuningResponsivenessHarness.glide(
            referenceHz: Self.a2, rate: rate, seconds: 7.0,
            centsAt: { t in -60.0 + 120.0 * (t / 6.0) }
        )

        let (frames, _) = AudioTestHelpers.replayTrace(
            samples: samples, sampleRate: rate, config: Self.config()
        )

        print("== SWEEP: true cents vs reported ==")
        print("   t  trueC    rawHz    cents    dispC    estC  state   reject")
        for (i, frame) in frames.enumerated() {
            guard i % 8 == 0 else { continue }
            let t = frame.captureEndSeconds
            let trueCents = -60.0 + 120.0 * (t / 6.0)
            let estCents = frame.rawFrequency > 0
                ? 1200.0 * log2(frame.rawFrequency / Self.a2)
                : Double.nan
            let r = frame.reading
            let cents = r.map { String(format: "%8.2f", $0.cents) } ?? "     nil"
            let dispC = r.map { String(format: "%8.2f", $0.displayCents) } ?? "     nil"
            print(String(format: "%6.3f %7.2f %8.3f %@ %@ %8.2f  %-7@ %@",
                         t, trueCents, frame.rawFrequency, cents, dispC, estCents,
                         frame.displayState as NSString,
                         (frame.rejection ?? "-") as NSString))
        }
    }
}

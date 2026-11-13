import Testing
import Foundation
@testable import StrumKit

/// What the precise path is for: a needle that rests while the string does.
///
/// The numbers asserted here are loose versions of what was measured when the path was
/// built. On the quiet C recording the string's fundamental stays within a cent for
/// three seconds; the reference path's needle wandered from −6 to +16 cents over the same
/// audio. These tests fail if that comes back.
@Suite("Precise pipeline: a steady string gives a steady needle")
struct PrecisePipelineTests {
    private static func ukulele(mode: TunerMode = .auto) -> ReadingEngine.Configuration {
        ReadingEngine.Configuration(Tuning.resolve(
            instrument: .ukulele, tuningId: "high-g", customMidi: [], mode: mode, a4: 440.0))
    }

    /// Every fresh needle position the engine reports for a stretch of audio.
    private static func needle(
        _ samples: [Float], rate: Double,
        configuration: ReadingEngine.Configuration,
        pipeline: ReadingEngine.Pipeline = .precise
    ) -> [TunerReading] {
        let engine = ReadingEngine(configuration: configuration, sampleRate: rate, pipeline: pipeline)
        var readings: [TunerReading] = []
        var start = 0
        while start < samples.count {
            let end = min(start + 1024, samples.count)
            readings += engine.push(Array(samples[start..<end]), sampleRate: rate)
                .compactMap(\.display.reading)
                .filter { $0.freshness == .fresh }
            start = end
        }
        return readings
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    /// A plucked string as a microphone hears it: partials that are not exact multiples,
    /// that decay at different rates, with noise underneath.
    private static func string(
        _ fundamental: Double, rate: Double, seconds: Double,
        inharmonicity: Double = 1e-4, noise: Double = 0.002, seed: UInt64 = 7
    ) -> [Float] {
        let count = Int(rate * seconds)
        var out = [Double](repeating: 0, count: count)
        var state = seed
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        for k in 1...16 {
            let f = Double(k) * fundamental * (1 + inharmonicity * Double(k * k)).squareRoot()
            guard f < rate * 0.45 else { break }
            let amplitude = 0.1 / pow(Double(k), 1.1) * (0.5 + random())
            let tau = 1.6 / (1 + 0.25 * Double(k))
            let phase = random() * 2 * .pi
            for i in 0..<count {
                let t = Double(i) / rate
                out[i] += amplitude * exp(-t / tau) * min(1, t / 0.004) * sin(2 * .pi * f * t + phase)
            }
        }
        return out.map { Float($0 + noise * (random() * 2 - 1)) }
    }

    @Test("A quiet string that does not move is shown not moving", arguments: ["quiet_c", "quiet_e"])
    func quietStringRests(fixture: String) throws {
        let wav = try #require(AudioTestHelpers.loadWav(name: fixture))
        let readings = Self.needle(wav.samples, rate: wav.sampleRate, configuration: Self.ukulele())
        try #require(readings.count > 20, "The string must be picked up")

        // Past the pluck itself, the needle stays in a narrow band for the whole note...
        let settled = readings.dropFirst(8).map(\.displayCents)
        let band = (settled.max() ?? 0) - (settled.min() ?? 0)
        #expect(band < 6.0, "Needle wandered across \(band) cents on a string that did not move")

        // ...and moves between updates by a fraction of a cent.
        let steps = zip(settled.dropFirst(), settled).map { abs($0 - $1) }
        #expect(Self.percentile(steps, 0.95) < 1.0)
    }

    @Test("The reference path wanders on the same audio, which is why it is not what runs")
    func referenceWandersOnQuietC() throws {
        let wav = try #require(AudioTestHelpers.loadWav(name: "quiet_c"))
        let reference = Self.needle(wav.samples, rate: wav.sampleRate, configuration: Self.ukulele(), pipeline: .reference)
            .map(\.displayCents)
        let band = (reference.max() ?? 0) - (reference.min() ?? 0)
        #expect(band > 12.0, "If the reference no longer wanders, the case for the precise path needs remaking")
    }

    @Test("A string is read to within a cent through noise and stretched partials",
          arguments: [(40, 48000.0), (45, 44100.0), (55, 48000.0), (64, 44100.0)])
    func stringIsReadAccurately(midi: Int, rate: Double) throws {
        let guitar = ReadingEngine.Configuration(Tuning.resolve(
            instrument: .guitar, tuningId: "standard", customMidi: [], mode: .auto, a4: 440.0))
        let truth = 3.0 // cents sharp
        let frequency = PitchMath.midiFrequency(midi) * pow(2, truth / 1200)
        let readings = Self.needle(Self.string(frequency, rate: rate, seconds: 3), rate: rate, configuration: guitar)
        try #require(readings.count > 60)

        let settled = readings.dropFirst(15).map(\.displayCents)
        // Within a cent and a half of the fundamental throughout: the partials above it
        // are sharp by up to several cents, and none of that may leak into the reading.
        #expect(settled.allSatisfy { abs($0 - truth) < 1.5 },
                "Read \(settled.min() ?? 0)...\(settled.max() ?? 0), true \(truth)")
        let steps = zip(settled.dropFirst(), settled).map { abs($0 - $1) }
        #expect(Self.percentile(steps, 0.95) < 0.3)
    }

    @Test("A peg turn is followed, not smoothed away")
    func pegTurnIsFollowed() throws {
        // A4, twenty cents flat, brought up to pitch over half a second, then held.
        let rate = 48000.0
        var phase = 0.0
        let samples: [Float] = (0..<Int(rate * 2.5)).map { i in
            let t = Double(i) / rate
            let cents = t < 1.0 ? -20.0 : (t < 1.5 ? -20.0 + 40.0 * (t - 1.0) : 0.0)
            phase += 2 * .pi * 440.0 * pow(2, cents / 1200) / rate
            return Float(0.1 * sin(phase) + 0.05 * sin(2 * phase))
        }
        let engine = ReadingEngine(configuration: Self.ukulele(), sampleRate: rate)
        var byTime: [(t: Double, cents: Double)] = []
        var position = 0
        while position < samples.count {
            let end = min(position + 1024, samples.count)
            for hop in engine.push(Array(samples[position..<end]), sampleRate: rate) {
                if let reading = hop.display.reading, reading.freshness == .fresh {
                    byTime.append((hop.trace.streamTimeMs / 1000, reading.displayCents))
                }
            }
            position = end
        }
        // Mid-turn, at 80 cents a second, the needle is about a tenth of a second behind
        // the string: half an analysis window plus the smoothing.
        let mid = try #require(byTime.last { $0.t <= 1.3 })
        #expect(abs(mid.cents - (-8.0)) < 9.0, "Mid-turn needle at \(mid.cents)")
        // A quarter of a second after the turn stops, it has arrived and stays.
        let after = byTime.filter { $0.t >= 1.75 }.map(\.cents)
        #expect(!after.isEmpty && after.allSatisfy { abs($0) < 1.0 })
    }

    @Test("Chromatic mode names a Note that is nowhere near a String, and smooths it")
    func chromaticIsChromatic() throws {
        // F♯3 on a ukulele tuned G C E A: six semitones from the nearest String.
        let rate = 44100.0
        let frequency = PitchMath.midiFrequency(54) * pow(2, 7.0 / 1200)
        let samples: [Float] = (0..<Int(rate * 1.5)).map { i in
            let t = Double(i) / rate
            return Float(0.1 * sin(2 * .pi * frequency * t) + 0.04 * sin(4 * .pi * frequency * t))
        }
        let readings = Self.needle(samples, rate: rate, configuration: Self.ukulele(mode: .chromatic))
        let last = try #require(readings.last)
        #expect(last.note == "F♯3")
        #expect(last.inTune == nil)
        #expect(abs(last.displayCents - 7.0) < 0.5)
    }

    @Test("In tune takes 400 ms of being there, and does not flicker at the edge")
    func inTuneIsConfirmedAndHeld() {
        let tracker = ReadingTracker()
        tracker.targets = [Target(note: "A4", midi: 69)]
        var time = 0.0
        var firstInTune: Double?
        // Dead on for a second.
        while time < 1000 {
            if tracker.push(frequency: 440.0, time: time)?.inTune == true, firstInTune == nil { firstInTune = time }
            time += 21.3
        }
        // Two hops to pick the String up, then 400 ms.
        #expect((firstInTune ?? 0) >= 400 && (firstInTune ?? 9999) < 520)

        // Hovering just outside tolerance does not drop a verdict already given...
        var verdicts: [Bool] = []
        while time < 2000 {
            verdicts.append(tracker.push(frequency: 440.0 * pow(2, 5.6 / 1200), time: time)?.inTune ?? false)
            time += 21.3
        }
        #expect(verdicts.allSatisfy { $0 })
        // ...and clearly leaving does.
        var left = true
        while time < 2600 {
            left = tracker.push(frequency: 440.0 * pow(2, 12.0 / 1200), time: time)?.inTune ?? false
            time += 21.3
        }
        #expect(!left)
    }
}

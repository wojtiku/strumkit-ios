import Foundation
import QuartzCore
import Testing
@testable import StrumKit

/// Measurement harness for a real four-strum-with-room-noise recording.
///
/// This is **not** a product test. It asserts almost nothing; its output is the
/// deliverable. Every frame is emitted as one `SEG|` line so the same summariser
/// can be pointed at the StrumKit trace and at the WebTuna/GuitarTuna trace
/// (`docs/tuner-reliability/webtuna/realfile.mjs`), which is what makes the two
/// comparable despite their different update cadences.
///
/// The recording is a **ukulele**, not a guitar: the four strums are
/// `Presets.ukulele` `high-g`, midi `[67, 60, 64, 69]` = G4 C4 E4 A4 = 391.995 /
/// 261.626 / 329.628 / 440.0 Hz. `uke+rec` and `uke-norec` are the runs that answer
/// the question. The guitar-auto runs are kept deliberately, and labelled
/// `auto+rec` / `auto-norec`, for the contrast: auto mode is a *closed* vocabulary
/// and correctly abstains outside it, so pointing it at guitar standard on a
/// ukulele recording should produce `targetMismatch` on every frame whose note is
/// far from an open guitar string. That is a feature of the design, and the guitar
/// rows are the control that shows it behaving that way.
///
/// Configurations, all over the identical audio:
///
/// - `uke+rec`   ukulele high-g, auto string assignment, recovery on.  **The run.**
/// - `uke-norec` the same with recovery off, isolating the recovery path.
/// - `auto+rec`  guitar standard, auto, recovery on.  Control: wrong vocabulary.
/// - `auto-norec` guitar standard, auto, recovery off.
/// - `chroma+rec` chromatic, recovery on. Auto mode has to both measure pitch *and*
///   decide which string a hit is; chromatic measures the pitch alone, so a
///   divergence between `uke+rec` and `chroma+rec` localises the fault to string
///   assignment rather than to the estimator.
///
/// The sample rate is read from the WAV header, never assumed, so this file also
/// exercises the 48 kHz resample path rather than the 44.1 kHz identity path.
@Suite("Real Strum Measurement (measurement harness, no quality gates)")
struct RealStrumMeasurementTests {

    /// Configurations under test, in print order.
    ///
    /// `label` is the `cfg` token in every emitted line, and the summariser groups
    /// on it, so these strings are load-bearing. The three guitar-era labels are
    /// unchanged so previously published numbers stay directly comparable.
    private struct Configuration {
        let label: String
        let instrument: InstrumentCategory
        let tuningId: String
        let mode: TunerMode
        let enableSpectralRecovery: Bool
    }

    private static let configurations: [Configuration] = [
        Configuration(label: "uke+rec", instrument: .ukulele, tuningId: "high-g",
                      mode: .auto, enableSpectralRecovery: true),
        Configuration(label: "uke-norec", instrument: .ukulele, tuningId: "high-g",
                      mode: .auto, enableSpectralRecovery: false),
        Configuration(label: "auto+rec", instrument: .guitar, tuningId: "standard",
                      mode: .auto, enableSpectralRecovery: true),
        Configuration(label: "auto-norec", instrument: .guitar, tuningId: "standard",
                      mode: .auto, enableSpectralRecovery: false),
        Configuration(label: "chroma+rec", instrument: .guitar, tuningId: "standard",
                      mode: .chromatic, enableSpectralRecovery: true)
    ]

    private static let fixtureName = "all-4-with-noise"

    @Test("emits a per-frame trace of a real four-strum recording in five configurations")
    func measureRealStrumSequence() {
        guard let wav = AudioTestHelpers.loadWav(name: Self.fixtureName) else {
            Issue.record("Failed to load fixture \(Self.fixtureName).wav from StrumKitTests/Fixtures")
            return
        }

        // Read from the file, never assumed. 48 kHz here, which means
        // `requiredInputSamples` returns the 48 kHz trailing window and every
        // frame after the first few goes through `Resampler.resampleWindow`.
        let sampleRate = wav.sampleRate
        let hop = AudioTestHelpers.productionHopSamples
        let duration = Double(wav.samples.count) / sampleRate

        print(String(
            format: "META|fixture=%@|frames=%d|rate=%.1f|dur=%.3f|hop=%d|hopms=%.2f|window=%d|windowms=%.1f",
            Self.fixtureName, wav.samples.count, sampleRate, duration, hop,
            1000.0 * Double(hop) / sampleRate,
            Resampler.requiredInputSamples(for: sampleRate),
            1000.0 * Double(Resampler.requiredInputSamples(for: sampleRate)) / sampleRate
        ))

        for configuration in Self.configurations {
            let config = TunerConfig(
                instrument: configuration.instrument,
                tuningId: configuration.tuningId,
                mode: configuration.mode
            )

            let started = CACurrentMediaTime()
            let trace = AudioTestHelpers.replayTrace(
                samples: wav.samples,
                sampleRate: sampleRate,
                config: config,
                hopSamples: hop,
                enableSpectralRecovery: configuration.enableSpectralRecovery
            )
            let elapsed = CACurrentMediaTime() - started

            let frames = trace.frames
            let heard = frames.filter { frame in
                guard frame.displayState != "none" else { return false }
                return (frame.reading?.frequency ?? 0) > 0
            }
            let histogram = AudioTestHelpers.stateHistogram(frames)

            // `hz` is the frequency the player sees (`reading.frequency`), which is
            // what a jitter complaint is about: a held reading repeats the last
            // fresh value, so display and estimator behaviour are separable.
            //
            // `raw` is the raw DSP estimate for the same frame, so the two can be
            // compared frame by frame to attribute jitter. `rej` is the reason no
            // fresh reading exists. Fields after `rej` are additive diagnostics;
            // the required prefix is unchanged.
            var lines: [String] = []
            lines.reserveCapacity(frames.count)
            for frame in frames {
                let reading = frame.reading
                let hz = reading?.frequency ?? 0
                let targetIndex = reading?.targetIndex ?? -9
                let cents = reading.map { $0.cents } ?? Double.nan
                let note = reading?.note ?? "-"
                let displayCents = reading?.displayCents ?? Double.nan
                let targetFrequency = reading?.target.frequency ?? 0
                let recovered = (reading?.recovered ?? false) ? 1 : 0

                lines.append(String(
                    format: "SEG|%@|t=%.4f|hz=%.4f|state=%@|tgt=%d|cents=%.3f|conf=%.4f|rej=%@|raw=%.4f|note=%@|tf=%.4f|dcents=%.3f|rec=%d|rms=%.6f",
                    configuration.label,
                    frame.captureEndSeconds,
                    hz,
                    frame.displayState,
                    targetIndex,
                    cents,
                    frame.confidence,
                    frame.rejection ?? "-",
                    frame.rawFrequency,
                    note,
                    targetFrequency,
                    displayCents,
                    recovered,
                    frame.rawRMS
                ))
            }

            for line in lines { print(line) }

            // Cross-check for the Python summariser, which recomputes the same
            // number from the emitted `state` column. The two must agree.
            print(String(
                format: "SUM|cfg=%@|frames=%d|heard=%d|transitions=%d|histogram=%@|ms=%.0f",
                configuration.label,
                frames.count,
                heard.count,
                AudioTestHelpers.countDisplayTransitions(frames),
                Self.renderHistogram(histogram),
                elapsed * 1000.0
            ))
        }
    }

    private static func renderHistogram(_ histogram: [String: Int]) -> String {
        let order = ["none", "fresh", "held", "recovered"]
        return order
            .sorted { (histogram[$0] ?? 0) > (histogram[$1] ?? 0) }
            .map { "\($0)=\(histogram[$0] ?? 0)" }
            .joined(separator: ",")
    }
}

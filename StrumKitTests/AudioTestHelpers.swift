import Foundation
@testable import StrumKit

public enum AudioTestHelpers {

    /// Generates pure synthetic sine wave samples matching chorder's tone() helper.
    public static func tone(frequency: Double, rate: Double, amplitude: Float = 0.1) -> [Float] {
        let length = Int(ceil(rate * 0.1))
        var samples = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let t = Double(i) / rate
            samples[i] = amplitude * Float(sin(2.0 * Double.pi * frequency * t))
        }
        return samples
    }

    /// Known phase-derived fundamental, seeded noise, transient attack, and decay matching chorder's pluck() helper.
    public static func pluck(
        rate: Double,
        frequency: Double,
        seconds: Double = 1.4,
        snr: Double = .infinity,
        initialSeed: UInt64 = 42
    ) -> [Float] {
        let length = Int(round(rate * seconds))
        var signal = [Float](repeating: 0, count: length)

        for i in 0..<length {
            let t = Double(i) / rate
            let angle = 2.0 * Double.pi * frequency * t
            let attack = min(1.0, t / 0.006)
            let decay = exp(-t / 1.8)
            let envelope = Float(attack * decay)

            let h1 = 0.09 * sin(angle)
            let h2 = 0.15 * sin(2.0 * angle + 0.4)
            let h3 = 0.055 * sin(3.0 * angle + 0.8)
            signal[i] = envelope * Float(h1 + h2 + h3)
        }

        if !snr.isFinite { return signal }

        var sumSq: Double = 0.0
        for s in signal { sumSq += Double(s * s) }
        let rms = sqrt(sumSq / Double(signal.count))
        let amplitude = Float(rms * pow(10.0, -snr / 20.0) * sqrt(3.0))

        var seed = initialSeed
        for i in 0..<signal.count {
            seed = (seed &* 48271) % 2147483647
            let randNorm = (Float(seed) / 2147483647.0) * 2.0 - 1.0
            signal[i] += amplitude * randNorm
        }

        return signal
    }

    /// Parses a standard 16-bit PCM WAV file into Float samples normalized to [-1.0, 1.0].
    public static func loadWav(name: String) -> (samples: [Float], sampleRate: Double)? {
        let bundle = Bundle(for: BundleLocator.self)
        var wavUrl: URL? = bundle.url(forResource: name, withExtension: "wav")

        if wavUrl == nil {
            // Fall back to the source-relative fixtures directory. Derived from
            // #filePath rather than a hardcoded home directory so the suite runs
            // from any checkout and in CI.
            let thisFile = URL(fileURLWithPath: #filePath)
            let fixturesDir = thisFile.deletingLastPathComponent().appendingPathComponent("Fixtures")
            let localUrl = fixturesDir.appendingPathComponent("\(name).wav")
            if FileManager.default.fileExists(atPath: localUrl.path) {
                wavUrl = localUrl
            }
        }

        guard let url = wavUrl, let data = try? Data(contentsOf: url) else {
            return nil
        }

        return parseWavData(data)
    }

    private static func readUInt32LE(data: Data, offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt16LE(data: Data, offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) |
            (UInt16(data[offset + 1]) << 8)
    }

    private static func readInt16LE(data: Data, offset: Int) -> Int16 {
        let u = readUInt16LE(data: data, offset: offset)
        return Int16(bitPattern: u)
    }

    private static func parseWavData(_ data: Data) -> (samples: [Float], sampleRate: Double)? {
        guard data.count > 44 else { return nil }

        var sampleRate: Double = 44100.0
        var channels: Int = 1
        var bitsPerSample: Int = 16
        var dataOffset = 0
        var dataLength = 0

        var offset = 12
        while offset + 8 <= data.count {
            let chunkId = String(decoding: data[offset..<offset+4], as: UTF8.self)
            let chunkSize = Int(readUInt32LE(data: data, offset: offset + 4))
            let start = offset + 8

            if chunkId == "fmt " {
                let audioFormat = Int(readUInt16LE(data: data, offset: start))
                guard audioFormat == 1 || audioFormat == 65534 else { return nil } // PCM or WAVE_FORMAT_EXTENSIBLE
                channels = Int(readUInt16LE(data: data, offset: start + 2))
                sampleRate = Double(readUInt32LE(data: data, offset: start + 4))
                bitsPerSample = Int(readUInt16LE(data: data, offset: start + 14))
            }

            if chunkId == "data" {
                dataOffset = start
                dataLength = chunkSize
                break
            }

            offset = start + chunkSize + (chunkSize % 2)
        }

        guard dataOffset > 0 && bitsPerSample == 16 && channels > 0 else { return nil }

        let bytesPerSample = 2
        let frameSize = bytesPerSample * channels
        let availableBytes = min(dataLength, data.count - dataOffset)
        let sampleCount = availableBytes / frameSize
        var samples = [Float](repeating: 0, count: sampleCount)

        for i in 0..<sampleCount {
            let sampleVal = readInt16LE(data: data, offset: dataOffset + i * frameSize)
            samples[i] = Float(sampleVal) / 32768.0
        }

        return (samples, sampleRate)
    }

    /// Frame-by-frame diagnostic record for production replay simulations.
    public struct ReplayFrame: Sendable {
        public let captureEndSeconds: Double
        public let rawFrequency: Double
        public let rawRMS: Double
        public let confidence: Double
        public let rejection: String? // "gate", "clipping", "noPeriodicity", "ambiguity", "targetMismatch", "acquiring"
        public let reading: TunerReading?
        /// Which display state produced this frame: "none", "fresh", "held" or
        /// "recovered". Derived from the reading rather than stored on it, so the
        /// public `TunerReading` API is not widened for a test concern.
        public let displayState: String

        /// - Parameter displayState: normally left `nil`, which derives the state
        ///   from `reading` and so cannot drift from it. A hand-built frame passes
        ///   an explicit state to exercise states a real reading cannot represent,
        ///   such as a transition trace with no readings behind it.
        public init(
            captureEndSeconds: Double,
            rawFrequency: Double,
            rawRMS: Double,
            confidence: Double,
            rejection: String?,
            reading: TunerReading?,
            displayState: String? = nil
        ) {
            self.captureEndSeconds = captureEndSeconds
            self.rawFrequency = rawFrequency
            self.rawRMS = rawRMS
            self.confidence = confidence
            self.rejection = rejection
            self.reading = reading
            self.displayState = displayState ?? AudioTestHelpers.displayState(for: reading)
        }
    }

    /// Evaluates if an estimated frequency falls within 50 cents of the target reference.
    public static func isCorrectRecordedPitch(_ frequency: Double, reference: Double) -> Bool {
        guard frequency.isFinite, frequency > 0, reference > 0 else { return false }
        return abs(1200 * log2(frequency / reference)) <= 50
    }

    /// Classifies why a frame produced no usable fresh reading.
    ///
    /// The distinctions matter when reading a trace: YIN returning
    /// `isSignalPresent == true` with no frequency means it heard something
    /// periodic but refused to name a pitch (an ambiguity rejection), which is a
    /// very different situation from the level gate or from a target mismatch.
    public static func classifyRejection(
        pitchResult: PitchResult,
        noiseGate: Float,
        reading: TunerReading?,
        feedbackState: SignalFeedbackState
    ) -> String? {
        if pitchResult.isClipped { return "clipping" }

        if !pitchResult.isSignalPresent {
            return pitchResult.amplitudeRMS < Double(noiseGate) ? "gate" : "noPeriodicity"
        }

        // Signal present but no frequency: YIN's ambiguity / abstention path.
        if pitchResult.frequency <= 0 { return "ambiguity" }

        guard reading == nil else { return nil }

        switch feedbackState {
        case .checking: return "acquiring"
        case .ambiguous: return "ambiguity"
        default: return "targetMismatch"
        }
    }

    /// The display state a reading represents: one of "none", "fresh", "held" or
    /// "recovered".
    ///
    /// "recovered" wins over "held" because a recovered reading is the more
    /// specific fact about the frame, and the display treats it as its own state.
    public static func displayState(for reading: TunerReading?) -> String {
        guard let reading else { return "none" }
        if reading.recovered { return "recovered" }
        return reading.freshness == .fresh ? "fresh" : "held"
    }

    /// Whether this frame's estimate came from a measurement taken on this frame,
    /// as opposed to being a copy of an earlier one that the display is still
    /// republishing.
    ///
    /// **`freshness == .fresh` is a different question and must not be used as
    /// one.** `freshness` is a *state the display is in*, and the display state
    /// is derived from it — here, in `TunerPresentation`, and in `TunerViewModel`,
    /// which dims on `freshness == .held`. Continuation hysteresis republishes
    /// the last measured reading verbatim to hold the display through a dropout
    /// shorter than `PitchTracker.continuationYinFailuresToWeaken`: `at`
    /// advanced, `lastFreshAt` unchanged, `freshness: .fresh`. There is no other
    /// way to say "still fresh, not re-measured" in the current encoding, so a
    /// held-through frame is indistinguishable from a fresh one by `freshness`
    /// alone. That is a deliberate property of the display contract, not a
    /// defect; it just means `freshness` answers "what is on screen?" and not
    /// "what did the estimator just measure?".
    ///
    /// The distinction matters the moment a filter counts observations. A
    /// held-through frame carries the *same* frequency, note and cents as the
    /// frame it copies, up to 3 frames earlier, so treating it as an
    /// independent observation inflates counts and — worse — moves the
    /// reference that an accuracy metric compares against. Measured on
    /// `quiet_c` in auto mode, switching this filter moved the YIN anchor from
    /// +8.30 ¢ to +1.25 ¢ and a recovered-frame bias metric from −7.02 ¢ to
    /// −0.19 ¢, with no change in the scorer, purely by reweighting pinned
    /// copies against themselves. `lastFreshAt` is the field `TunerReading`
    /// exists to carry for exactly this question.
    ///
    /// So: use `freshness` / `displayState(for:)` when the claim is about the
    /// display — transition counts, state histograms, hold and `held` contracts.
    /// Use this when the claim is about the estimator — detection counts,
    /// correct/wrong-note tallies, cent error percentiles, bias, and "what was
    /// the last time we actually measured this note?".
    public static func wasMeasuredThisFrame(_ reading: TunerReading) -> Bool {
        reading.lastFreshAt == reading.at
    }

    /// Number of times the display state changed, ignoring consecutive repeats.
    ///
    /// This is the primary gate for goal G1: a note that is read continuously
    /// should acquire once and then hold, not oscillate between fresh, held and
    /// recovered while it decays.
    ///
    /// The floor is **1, not 0**. The loop counts every frame whose state differs
    /// from the one before it, and frame 0 always differs from the empty prefix,
    /// so what the subtraction removes is the first frame's *appearance*. Every
    /// change after it is kept, including the `none -> fresh` acquisition step.
    /// A trace that acquires once and then holds therefore scores exactly 1.
    public static func countDisplayTransitions(_ frames: [ReplayFrame]) -> Int {
        var transitions = 0
        var previous: String?
        for frame in frames {
            if frame.displayState != previous { transitions += 1 }
            previous = frame.displayState
        }
        return max(0, transitions - 1)   // the first frame is acquisition, not a transition
    }

    /// Counts of each display state across a trace, for attributing a transition
    /// to a specific state change rather than to a bare count.
    public static func stateHistogram(_ frames: [ReplayFrame]) -> [String: Int] {
        frames.reduce(into: [:]) { $0[$1.displayState, default: 0] += 1 }
    }

    /// How long, in seconds, a **correct** note was on the display inside an
    /// evaluation interval.
    ///
    /// **This is a display-duration measure, and it is deliberately not the
    /// honest per-frame predicate.** It filters on `freshness == .fresh`, not on
    /// `wasMeasuredThisFrame`, because a coverage figure answers "how long did
    /// the needle sit on the right note?" and continuation hysteresis
    /// deliberately keeps the needle up through short dropouts by republishing
    /// the last measurement. That is the display behaving as specified, and a
    /// duration that excluded it would understate what a player sees.
    ///
    /// It is also not a measure of how often the estimator *measured* the note,
    /// and the gap is large enough to matter: on `quiet_a` in auto mode this
    /// returns 1.835 s while the measured coverage is 0.747 s, i.e. 59 % of the
    /// needle's time on that pluck is display hold rather than confirmation. For
    /// the measurement question, count `wasMeasuredThisFrame` over the interval
    /// instead. Two callers gate on this number (`RecordedAudioTests` 0.40 s,
    /// `RealStrumStabilityTests` 1.00 s) and both were calibrated against it as a
    /// display measure, so its contract is stated here rather than changed under
    /// them.
    public static func freshCoverageSeconds(
        frames: [ReplayFrame],
        reference: Double,
        intervalStart: Double,
        intervalEnd: Double
    ) -> Double {
        var coverage: Double = 0.0
        var previousTime: Double = intervalStart

        for frame in frames {
            let t = frame.captureEndSeconds
            guard t >= intervalStart && t <= intervalEnd else { continue }
            if let reading = frame.reading, reading.freshness == .fresh, isCorrectRecordedPitch(reading.frequency, reference: reference) {
                let delta = max(0.0, t - max(intervalStart, previousTime))
                coverage += delta
            }
            previousTime = t
        }
        return coverage
    }

    /// Hop size, in samples, that the live capture path requests.
    ///
    /// The live adapter installs its tap with this buffer size and asks the session
    /// for a 20 ms preferred I/O duration, so production analyses audio roughly
    /// every 1024 frames. Replay that uses 2048-sample hops measures the pipeline at
    /// half the production update rate, which is why the default here matches the
    /// live request.
    ///
    /// This is a *requested* size: the OS is free to deliver larger buffers, which
    /// is why the live path used to be the only place reporting the actual
    /// `callbackFrameCount`. Since the microphone seam, tap size is the adapter's
    /// own decision and the live path does not report it; this constant is what
    /// replay stamps instead.
    public static let productionHopSamples = 1024

    /// Peak amplitude of an injected dropout window, as a fraction of the peak
    /// level of the signal under replay.
    ///
    /// Chosen so the replacement clears the tracker's level gate — around 0.0003
    /// RMS for a quiet room, since the floor starts at 0.0002 and only adapts
    /// after 0.35 s of continuous non-foreground audio — while staying two orders
    /// of magnitude below the note. A dropout that failed the gate would test the
    /// wrong branch: the pipeline would report "nothing here" rather than "here,
    /// but no pitch", and the reported symptom is about the second case.
    ///
    /// The fraction is relative, so a cell quiet enough that 1% of its peak falls
    /// under the gate yields a `gate` rejection instead. That is the correct
    /// outcome for a level the detector could not hear anyway, but it means this
    /// constant bounds the fixture's usable `lvl-` range rather than removing it.
    public static let dropoutNoiseFraction: Double = 0.01

    /// Which frames a given dropout rate loses.
    ///
    /// A dropout is a per-frame loss of signal, so it is a replay-time construct:
    /// no waveform can express it. Selection is a Park-Miller walk, the same
    /// generator `CoverageMatrix.signal` uses, so one seed fully determines it and
    /// seed A and seed B drop different frames.
    public static func droppedFrameIndices(frameCount: Int, rate: Double, seed: UInt64) -> [Int] {
        guard frameCount > 0, rate > 0 else { return [] }
        var lcg = seed % 2147483647
        if lcg == 0 { lcg = 1 }
        var dropped: [Int] = []
        for index in 0..<frameCount {
            lcg = (lcg &* 48271) % 2147483647
            if Double(lcg) / 2147483647.0 < rate { dropped.append(index) }
        }
        return dropped
    }

    /// A window of `count` samples containing noise and nothing else, at the
    /// level a real dropout presents: audible to the level gate, aperiodic to YIN.
    ///
    /// Seeded per frame so two runs replay the same dropout at the same frames
    /// sample for sample. Always built at the full analysis length, which is what
    /// keeps `PitchDetector.bufferSize` stable for all but the first 4 frames:
    /// the trailing window is still filling then, so the real branch is 1024,
    /// 2048, 3072 or 4096 samples and an injected one is `windowLength` (4328),
    /// which rebuilds the detector for that frame.
    private static func dropoutWindow(samples count: Int, level: Double, seed: UInt64) -> [Float] {
        let peak = Float(level * dropoutNoiseFraction)
        var lcg = seed % 2147483647
        if lcg == 0 { lcg = 1 }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            lcg = (lcg &* 48271) % 2147483647
            let uniform = Double(lcg) / 2147483647.0
            out[i] = peak * Float(uniform * 2 - 1)
        }
        return out
    }

    /// Production-equivalent replay trace with trailing capture windows, dynamic
    /// tracker thresholds, and the live request cadence.
    ///
    /// - Parameters:
    ///   - yinDropoutRate: fraction of frames to lose the signal on, per spec §6's
    ///     decay-with-dropout family. A dropped frame is analysed as a window of
    ///     noise at the cell's level rather than as the real audio, which is what
    ///     a dropped frame looks like to the detector. Defaults to `0.0`, which
    ///     drops nothing and leaves the trace exactly as production would.
    ///   - dropoutSeed: seed for the frame selection. The same seed always drops
    ///     the same frames; a different seed drops a different set.
    ///   - fundamentalEnergyScale: the one multiplier behind `PitchDetector`'s
    ///     three fundamental-energy gates. Defaults to `1.0`, which is the
    ///     pre-2026-09-25 behaviour and therefore what every other suite here is
    ///     calibrated against; a sweep passes a smaller value.
    public static func replayTrace(
        samples: [Float],
        sampleRate: Double,
        config: TunerConfig,
        hopSamples: Int = productionHopSamples,
        enableSpectralRecovery: Bool = true,
        fundamentalEnergyScale: Double = PitchDetector.defaultFundamentalEnergyScale,
        yinDropoutRate: Double = 0.0,
        dropoutSeed: UInt64 = 1
    ) -> (frames: [ReplayFrame], tracker: PitchTracker) {
        // A config handed to the replay path has already been through the resolution
        // once, and resolution is idempotent, so re-resolving here yields the same
        // Targets the app would build — from the one place that knows how.
        let targets = Tuning.resolve(
            instrument: config.instrument,
            tuningId: config.tuningId,
            customMidi: config.customMidi,
            mode: config.mode,
            a4: config.a4,
            precision: config.precision,
            guided: config.guided,
            selectedString: config.selectedString
        ).targets

        let tracker = PitchTracker()
        tracker.reset(targetCount: targets.count)
        let session = TunerAnalysisSession(
            config: config, targets: targets, tracker: tracker,
            fundamentalEnergyScale: fundamentalEnergyScale)
        session.isSpectralRecoveryEnabled = enableSpectralRecovery

        var frames: [ReplayFrame] = []
        let windowLength = Resampler.requiredInputSamples(for: sampleRate)
        var sequence: UInt64 = 0

        let frameCount = samples.count >= hopSamples
            ? (samples.count - hopSamples) / hopSamples + 1
            : 0

        // The dropout block is skipped when nothing is dropped, so the default
        // uninjected path costs exactly what it cost before this parameter
        // existed. The peak reduction is O(n) over the whole signal and exists
        // only to scale the injected noise. `droppedFrameIndices` is left
        // unconditional: it is the selection's own definition and is tested
        // directly.
        var dropped: Set<Int> = []
        var signalPeak: Double = 0
        if yinDropoutRate > 0 {
            dropped = Set(droppedFrameIndices(
                frameCount: frameCount, rate: yinDropoutRate, seed: dropoutSeed))
            // The cell's level, as realised in the audio. `signal` restores the
            // requested peak on the finite-SNR path, and leaves the raw harmonic
            // sum scaled by `amplitude` otherwise, so this is the case's
            // configured `lvl-` amplitude to within the peak factor of its
            // partials.
            signalPeak = Double(samples.reduce(Float(0)) { max($0, abs($1)) })
        }
        var frameOrdinal = 0

        for endSample in stride(from: hopSamples, through: samples.count, by: hopSamples) {
            let isDropped = dropped.contains(frameOrdinal)
            let startSample = max(0, endSample - windowLength)
            let window = isDropped
                ? dropoutWindow(samples: windowLength, level: signalPeak,
                                seed: dropoutSeed &+ UInt64(frameOrdinal))
                : Array(samples[startSample..<endSample])
            frameOrdinal += 1
            sequence &+= 1
            let atSeconds = Double(endSample) / sampleRate

            let frame = AnalysisFrame(
                samples: window,
                sampleRate: sampleRate,
                captureEndSeconds: atSeconds,
                sequence: sequence,
                generation: session.generation,
                callbackFrameCount: hopSamples
            )

            guard let snapshot = session.processFrameSync(frame) else { continue }

            let rejection = AudioTestHelpers.classifyRejection(
                pitchResult: snapshot.pitchResult,
                noiseGate: tracker.recommendedNoiseGate(isSustaining: false),
                reading: snapshot.reading,
                feedbackState: snapshot.feedbackState
            )

            frames.append(ReplayFrame(
                captureEndSeconds: atSeconds,
                rawFrequency: snapshot.pitchResult.frequency,
                rawRMS: snapshot.pitchResult.amplitudeRMS,
                confidence: snapshot.pitchResult.confidence,
                rejection: rejection,
                reading: snapshot.reading,
                displayState: displayState(for: snapshot.reading)
            ))
        }

        return (frames, tracker)
    }

    /// Replays audio through PitchDetector and PitchTracker (adapter for existing tests).
    public static func replay(
        samples: [Float],
        sampleRate: Double,
        config: TunerConfig
    ) -> (readings: [TunerReading], tracker: PitchTracker) {
        let (frames, tracker) = replayTrace(samples: samples, sampleRate: sampleRate, config: config)
        let readings = frames.compactMap { $0.reading }
        return (readings, tracker)
    }
}

private final class BundleLocator {}

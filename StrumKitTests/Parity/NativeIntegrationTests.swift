// StrumKitTests/Parity/NativeIntegrationTests.swift
import Foundation
import Testing
@testable import StrumKit

@Suite("Native Integration and Session Parity Tests")
struct NativeIntegrationTests {

    private func makeTone(frequency: Double, sampleRate: Double = 44100.0, amplitude: Float = 0.1, count: Int = 4096) -> [Float] {
        var buffer = [Float](repeating: 0, count: count)
        for i in 0..<count {
            buffer[i] = amplitude * Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
        return buffer
    }

    @MainActor
    private func settled() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }

    // MARK: - 1. Session Replay vs Standalone Engine Parity

    @Test("Direct replay through TunerAnalysisSession matches standalone faithful engine bit-for-bit")
    func testSessionReplayMatchesStandaloneEngine() {
        let config = TunerConfig(instrument: .ukulele, tuningId: "standard", a4: 440.0, mode: .auto)
        let resolved = Tuning.resolve(
            instrument: config.instrument,
            tuningId: config.tuningId,
            customMidi: config.customMidi,
            mode: config.mode,
            a4: config.a4,
            precision: config.precision,
            guided: config.guided,
            selectedString: config.selectedString
        )
        let targets = resolved.targets

        // 1. Setup Standalone Engine
        let profile = FaithfulEngineProfile.profile(for: config.instrument, tuningId: config.tuningId)
        let standaloneDetector = FaithfulStreamingDetector(profile: profile)
        let standaloneAdapter = FaithfulReadingAdapter(mode: config.mode, calibrationA4: config.a4)
        standaloneAdapter.tuning = config.tuningId
        standaloneAdapter.targets = targets.map { Target(note: $0.note, frequency: $0.frequency, midi: $0.midi, stringNumber: $0.number) }
        standaloneAdapter.tracker.auto = true
        standaloneAdapter.tracker.selected = config.selectedString

        // 2. Setup TunerAnalysisSession (using faithful engine path, tracker: nil)
        let session = TunerAnalysisSession(config: config, targets: targets)

        let sampleRate = 44100.0
        let hopSamples = 1024
        let windowSize = 4096
        let totalSamples = windowSize + 15 * hopSamples
        let toneSamples = makeTone(frequency: 440.0, sampleRate: sampleRate, amplitude: 0.1, count: totalSamples)

        var frameSequence: UInt64 = 0

        for endSample in stride(from: windowSize, through: totalSamples, by: hopSamples) {
            frameSequence &+= 1
            let startSample = endSample - windowSize
            let window = Array(toneSamples[startSample..<endSample])
            let captureEndSeconds = Double(endSample) / sampleRate
            let timeMs = captureEndSeconds * 1000.0

            // Run standalone
            let standaloneCand = standaloneDetector.detect(input: window, sampleRate: sampleRate, sampleTime: timeMs)
            let standaloneOutput = standaloneAdapter.process(candidate: standaloneCand, timeMs: timeMs)

            // Run session
            let frame = AnalysisFrame(
                samples: window,
                sampleRate: sampleRate,
                captureEndSeconds: captureEndSeconds,
                sequence: frameSequence,
                generation: session.generation,
                callbackFrameCount: hopSamples
            )
            guard let snapshot = session.processFrameSync(frame) else {
                Issue.record("Expected snapshot from session on frame \(frameSequence)")
                continue
            }

            // Compare actions
            #expect(snapshot.action.isSkipped == standaloneOutput.action.isSkipped, "Action skipped mismatch at frame \(frameSequence)")
            #expect(snapshot.action.isPublished == standaloneOutput.action.isPublished, "Action published mismatch at frame \(frameSequence)")

            // Compare readings
            if let expectedReading = standaloneOutput.reading {
                guard let actualReading = snapshot.reading else {
                    Issue.record("Session reading was nil when standalone produced reading at frame \(frameSequence)")
                    continue
                }
                #expect(actualReading.cents == expectedReading.cents, "Cents deviation mismatch at frame \(frameSequence)")
                #expect(actualReading.inTune == expectedReading.inTune, "inTune mismatch at frame \(frameSequence)")
                #expect(actualReading.evidence == expectedReading.evidence, "Evidence mismatch at frame \(frameSequence)")
                #expect(actualReading.freshness == expectedReading.freshness, "Freshness mismatch at frame \(frameSequence)")
                #expect(actualReading.aim.target?.midi == expectedReading.aim.target?.midi, "Target MIDI mismatch at frame \(frameSequence)")

                // Sample-clock contract: TunerReading.at strictly reflects captureEndSeconds
                #expect(abs(actualReading.at - captureEndSeconds) < 1e-6, "Reading timestamp must strictly reflect sample-clock captureEnd")
            } else {
                #expect(snapshot.reading == nil, "Session produced reading when standalone was nil at frame \(frameSequence)")
            }
        }
    }

    // MARK: - 2. Session Generational Invalidation & Mailbox Safety

    @Test("TunerAnalysisSession invalidates generation and flushes pending frames on stop and config change")
    func testSessionGenerationalInvalidation() {
        let config = TunerConfig(instrument: .ukulele, tuningId: "standard", a4: 440.0, mode: .auto)
        let session = TunerAnalysisSession(config: config, targets: [])

        let gen1 = session.generation
        #expect(gen1 >= 1)

        session.stop()
        let gen2 = session.generation
        #expect(gen2 > gen1, "Stop must increment generation")

        // Submitting a frame from stale generation 1 must be rejected by processFrameSync
        let frameStale = AnalysisFrame(
            samples: [Float](repeating: 0, count: 4096),
            sampleRate: 44100.0,
            captureEndSeconds: 1.0,
            sequence: 1,
            generation: gen1,
            callbackFrameCount: 1024
        )
        let staleSnapshot = session.processFrameSync(frameStale)
        #expect(staleSnapshot == nil, "Stale generation frame must be rejected")

        let newConfig = TunerConfig(instrument: .guitar, tuningId: "standard", a4: 440.0, mode: .auto)
        session.updateConfiguration(newConfig)
        let gen3 = session.generation
        #expect(gen3 > gen2, "Configuration update must increment generation")

        let resolved = Tuning.resolve(
            instrument: .guitar,
            tuningId: "standard",
            customMidi: [],
            mode: .auto,
            a4: 440.0,
            precision: false,
            guided: false
        )
        session.adopt(resolved)
        let gen4 = session.generation
        #expect(gen4 > gen3, "Resolution adoption must increment generation")
    }

    // MARK: - 3. Reference Tone Coordination & Audio Isolation

    @Test("Reference tone playback pauses measurement, clears reading, and resumes on tone end")
    @MainActor
    func testReferenceTonePausesMeasurementAndResumes() async {
        let source = ScriptedMicrophone()
        let tone = RecordingReferenceTonePlayer()
        let viewModel = TestTuner.viewModel(source: source, referenceTone: tone)

        await viewModel.start()
        #expect(viewModel.engineStatus == .listening)
        #expect(source.isStarted)

        // Play reference tone for string 1
        viewModel.playReferenceTone(index: 1)
        #expect(tone.requestedTones.count == 1)
        #expect(tone.requestedTones.first?.stringIndex == 1)
        #expect(viewModel.engineStatus == .paused)
        #expect(viewModel.currentReading == nil)
        #expect(viewModel.feedbackState == .inactive)
        #expect(source.isStarted == false)

        // Simulate tone playback finishing
        tone.simulateToneEnded()
        await settled()

        // Listening intent was true, so listening resumes automatically
        #expect(viewModel.engineStatus == .listening)
        #expect(source.isStarted)
    }

    @Test("Rapid reference tone taps are guarded by toneGeneration and do not flap or loop")
    @MainActor
    func testRapidReferenceToneTapsGuarded() async {
        let source = ScriptedMicrophone()
        let tone = RecordingReferenceTonePlayer()
        let viewModel = TestTuner.viewModel(source: source, referenceTone: tone)

        await viewModel.start()
        #expect(source.startCount == 1)

        // Rapidly tap tone 0, 1, 2
        viewModel.playReferenceTone(index: 0)
        viewModel.playReferenceTone(index: 1)
        viewModel.playReferenceTone(index: 2)

        #expect(tone.requestedTones.count == 3)
        #expect(viewModel.engineStatus == .paused)

        // Multiple delayed tone-ended callbacks arrive
        tone.simulateToneEnded()
        await settled()

        // Resumes listening cleanly exactly once without loop
        #expect(viewModel.engineStatus == .listening)
        #expect(source.startCount == 2)
    }

    @Test("Stopping tuner while reference tone is playing keeps tuner paused")
    @MainActor
    func testStopWhileTonePlayingStaysPaused() async {
        let source = ScriptedMicrophone()
        let tone = RecordingReferenceTonePlayer()
        let viewModel = TestTuner.viewModel(source: source, referenceTone: tone)

        await viewModel.start()
        viewModel.playReferenceTone(index: 0)
        #expect(viewModel.engineStatus == .paused)

        // User stops the tuner
        viewModel.stop()
        #expect(viewModel.engineStatus == .paused)

        // Tone finishes later
        tone.simulateToneEnded()
        await settled()

        // Intent was cancelled, so microphone must remain stopped
        #expect(viewModel.engineStatus == .paused)
        #expect(source.isStarted == false)
    }

    // MARK: - 4. Production Bundle Audit

    @Test("Production app bundle configuration strictly excludes test fixtures and reference oracles")
    func testProductionBundleAudit() {
        let appBundle = Bundle.main
        let resourceURL = appBundle.resourceURL ?? appBundle.bundleURL
        let enumerator = FileManager.default.enumerator(at: resourceURL, includingPropertiesForKeys: nil)
        var forbiddenFiles: [String] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            // PlugIns contains the test bundle injected by xcodebuild for running unit tests
            if fileURL.path.contains("/PlugIns/") || fileURL.path.contains("/Frameworks/") {
                continue
            }
            let name = fileURL.lastPathComponent.lowercased()
            if name.hasSuffix(".wav") || name.hasSuffix(".aiff") || name.hasSuffix(".mp3") {
                forbiddenFiles.append(name)
            }
            if name.contains("corpus") || name.contains("oracle") || name.contains("fixture") {
                forbiddenFiles.append(name)
            }
        }

        #expect(forbiddenFiles.isEmpty, "Production bundle must not contain test audio or oracles: \(forbiddenFiles)")
    }
}

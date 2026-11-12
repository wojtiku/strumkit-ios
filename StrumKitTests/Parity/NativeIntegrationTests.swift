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

    @Test("Replay through TunerAnalysisSession shows exactly what the Reading engine reports")
    func testSessionReplayMatchesStandaloneEngine() {
        let resolved = Tuning.resolve(
            instrument: .ukulele, tuningId: "standard", customMidi: [],
            mode: .auto, a4: 440.0, precision: false, guided: false)

        let sampleRate = 44100.0
        let toneSamples = makeTone(frequency: 440.0, sampleRate: sampleRate, amplitude: 0.1, count: 4096 + 60 * 1024)

        let engine = ReadingEngine(configuration: ReadingEngine.Configuration(resolved))
        let session = TunerAnalysisSession(config: resolved.config, targets: resolved.targets)

        var expected: [TunerReading?] = []
        var actual: [TunerReading?] = []
        for start in stride(from: 0, to: toneSamples.count, by: 1024) {
            let chunk = Array(toneSamples[start..<min(start + 1024, toneSamples.count)])
            expected += engine.push(chunk, sampleRate: sampleRate)
                .filter { $0.display != .unchanged }
                .map(\.display.reading)
            actual += session.processSync(chunk, sampleRate: sampleRate).map(\.reading)
        }

        #expect(actual == expected)
        #expect(actual.contains { $0 != nil }, "The tone must produce a Reading")
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

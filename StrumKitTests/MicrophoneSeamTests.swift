import Testing
import Foundation
import QuartzCore
@testable import StrumKit

/// The audio lifecycle of the tuner, observed through something that is not a
/// microphone. Every test here crosses the seam: a scripted source, a recording
/// tone player, and no `AVAudioSession`.
@Suite("Microphone Seam Tests")
struct MicrophoneSeamTests {

    @Test("A denied microphone is never started")
    @MainActor
    func testDeniedPermissionNeverStartsTheSource() async {
        let source = ScriptedMicrophone(permissionStatus: .denied)
        let viewModel = TestTuner.viewModel(source: source)

        await viewModel.start()

        #expect(viewModel.engineStatus == .denied)
        #expect(source.startCount == 0)
        #expect(source.isStarted == false)
        #expect(source.permissionRequestCount == 0)
    }

    @Test("An interruption leaves the source stopped, not merely the analysis")
    @MainActor
    func testInterruptionLeavesTheSourceStopped() async {
        let source = ScriptedMicrophone()
        let viewModel = TestTuner.viewModel(source: source)

        await viewModel.start()
        #expect(source.isStarted)

        source.raise(.interrupted(resumable: false))
        await settled()

        // The tap itself, not just the analysis behind it: a "stop" that leaves the
        // tap installed keeps delivering windows stamped with the new generation, so
        // the tuner would keep publishing through the interruption.
        #expect(source.isStarted == false)
        #expect(source.stopCount == 1)
        #expect(viewModel.engineStatus == .interrupted)
    }

    @Test("A resumable interruption restarts only when listening was intentional")
    @MainActor
    func testResumableInterruptionRestartsOnlyIfListeningWasIntentional() async {
        // An interruption that ends with the system inviting a resume, while the
        // player meant to be listening: capture is picked up again.
        let listening = ScriptedMicrophone()
        let listeningViewModel = TestTuner.viewModel(source: listening)
        await listeningViewModel.start()

        listening.raise(.interrupted(resumable: false))
        await settled()
        #expect(listening.isStarted == false)

        listening.raise(.interrupted(resumable: true))
        await settled()

        #expect(listening.startCount == 2)
        #expect(listening.isStarted)
        #expect(listeningViewModel.engineStatus == .listening)

        // The same interruption ending, but the player had deliberately stopped: the
        // tuner must stay stopped rather than open the microphone behind their back.
        let stopped = ScriptedMicrophone()
        let stoppedViewModel = TestTuner.viewModel(source: stopped)
        await stoppedViewModel.start()
        stoppedViewModel.stop()

        stopped.raise(.interrupted(resumable: true))
        await settled()

        #expect(stopped.startCount == 1)
        #expect(stopped.isStarted == false)
        #expect(stoppedViewModel.engineStatus == .paused)
    }

    @Test("A route change restarts capture, but only while listening")
    @MainActor
    func testRouteChangeRestartsCapture() async {
        let source = ScriptedMicrophone()
        let viewModel = TestTuner.viewModel(source: source)
        await viewModel.start()

        source.raise(.routeChanged)
        await settled()

        // A running tap is on the wrong input after a route change, so capture is
        // picked up again on the new one.
        #expect(source.startCount == 2)
        #expect(source.isStarted)
        #expect(viewModel.engineStatus == .listening)

        viewModel.stop()
        source.raise(.routeChanged)
        await settled()

        #expect(source.startCount == 2)
        #expect(source.isStarted == false)
        #expect(viewModel.engineStatus == .paused)
    }

    @Test("A reference tone is requested even when the microphone is denied")
    @MainActor
    func testReferenceToneIsRequestedEvenWhenTheMicIsDenied() async {
        let source = ScriptedMicrophone(permissionStatus: .denied)
        let tone = RecordingReferenceTonePlayer()
        let viewModel = TestTuner.viewModel(source: source, referenceTone: tone)

        await viewModel.start()
        #expect(viewModel.engineStatus == .denied)
        #expect(source.startCount == 0)

        // Reference tones are the documented fallback when the microphone is blocked
        // ("You can still use reference tones"), so the denied status must not stop
        // the player reaching for one.
        viewModel.playReferenceTone(index: 0)

        #expect(tone.requestedTones.count == 1)
        #expect(tone.requestedTones.first?.frequency == viewModel.targets[0].frequency)
        #expect(tone.requestedTones.first?.stringIndex == 0)
        #expect(tone.requestedTones.first?.instrument == .guitar)
        #expect(viewModel.lastTone?.source == .reference)
        #expect(source.startCount == 0)
    }

    @Test("Changing instrument replaces the target list and clears the Reading")
    @MainActor
    func testChangingInstrumentReplacesTargetsAndClearsReading() {
        let source = ScriptedMicrophone()
        let session = TunerAnalysisSession()
        let viewModel = TestTuner.viewModel(source: source, session: session)

        let now = CACurrentMediaTime()
        let guitarLowE = viewModel.targets[0]
        viewModel.handleSnapshot(
            AnalysisSnapshot(
                reading: TunerReading(
                    at: now,
                    lastFreshAt: now,
                    frequency: guitarLowE.frequency,
                    note: guitarLowE.note,
                    target: guitarLowE,
                    targetIndex: 0,
                    cents: 0.0,
                    displayCents: 0.0,
                    freshness: .fresh,
                    inTune: true
                ),
                pitchResult: PitchResult(
                    frequency: guitarLowE.frequency,
                    closestNote: MusicalNote(midiNoteNumber: guitarLowE.midi),
                    centsDeviation: 0.0,
                    confidence: 0.9,
                    amplitudeRMS: 0.05,
                    isSignalPresent: true
                ),
                feedbackState: .tracking,
                guidedProgress: [],
                guidedTargetIndex: 0,
                diagnostics: TunerDiagnostics(),
                generation: session.generation,
                sequence: 1
            )
        )
        #expect(viewModel.currentReading?.targetIndex == 0)

        viewModel.setInstrument(.ukulele)

        // The Reading was measured against a String the new Instrument does not have,
        // so it is cleared rather than re-pointed at whatever now sits at index 0.
        #expect(viewModel.currentReading == nil)
        #expect(viewModel.config.instrument == .ukulele)
        #expect(viewModel.targets.map(\.midi) == [67, 60, 64, 69])
    }

    /// Lets the main actor finish absorbing what the microphone reported.
    ///
    /// The tuner absorbs an event on the main actor deliberately, and a restart it
    /// decides on is a further hop, so a test that raises an event yields a few times
    /// before asserting. Both hops are already queued, so the yields are not a retry:
    /// they let the main actor run the work that is waiting for it.
    @MainActor
    private func settled() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }
}

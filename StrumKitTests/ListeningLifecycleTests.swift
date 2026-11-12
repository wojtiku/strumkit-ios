import Testing
import Foundation
@testable import StrumKit

/// The listening lifecycle on its own: a scripted microphone, a recording tone player,
/// a session, and no view model.
@Suite("Listening lifecycle")
@MainActor
struct ListeningLifecycleTests {
    private struct Rig {
        let source: ScriptedMicrophone
        let tone: RecordingReferenceTonePlayer
        let session: TunerAnalysisSession
        let lifecycle: ListeningLifecycle
        let statuses: StatusLog
    }

    private final class StatusLog {
        var seen: [EngineStatus] = []
    }

    private func makeRig(source: ScriptedMicrophone = ScriptedMicrophone()) -> Rig {
        let resolved = Tuning.resolve(TunerPreferences())
        let tone = RecordingReferenceTonePlayer()
        let session = TunerAnalysisSession(config: resolved.config, targets: resolved.targets)
        let lifecycle = ListeningLifecycle(source: source, referenceTone: tone, session: session, tuning: { resolved })
        let statuses = StatusLog()
        lifecycle.onStatusChange = { statuses.seen.append($0) }
        return Rig(source: source, tone: tone, session: session, lifecycle: lifecycle, statuses: statuses)
    }

    /// Lets work the lifecycle hopped to the main actor run.
    private func settled() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    @Test("Starting arms the microphone and reports listening")
    func startArmsTheMicrophone() async {
        let rig = makeRig()
        await rig.lifecycle.start()
        #expect(rig.lifecycle.status == .listening)
        #expect(rig.source.isStarted)
        #expect(rig.statuses.seen == [.listening])
    }

    @Test("A denied microphone is never started, and never asked again")
    func deniedMicrophoneIsNeverStarted() async {
        let rig = makeRig(source: ScriptedMicrophone(permissionStatus: .denied))
        await rig.lifecycle.start()
        #expect(rig.lifecycle.status == .denied)
        #expect(rig.source.startCount == 0)
        #expect(rig.source.permissionRequestCount == 0)
    }

    @Test("An undetermined permission is requested once, and a refusal is reported")
    func refusedPermissionIsReported() async {
        let rig = makeRig(source: ScriptedMicrophone(permissionStatus: .notDetermined, permissionRequestResult: false))
        await rig.lifecycle.start()
        #expect(rig.statuses.seen == [.requesting, .denied])
        #expect(rig.source.permissionRequestCount == 1)
        #expect(rig.source.startCount == 0)
    }

    @Test("Stopping pauses capture and invalidates the analysis")
    func stopPauses() async {
        let rig = makeRig()
        await rig.lifecycle.start()
        let generation = rig.session.generation
        rig.lifecycle.stop()
        #expect(rig.lifecycle.status == .paused)
        #expect(rig.source.isStarted == false)
        #expect(rig.session.generation > generation)
    }

    @Test("A reference tone takes the microphone, and gives it back when it ends")
    func toneHandsTheMicrophoneBack() async {
        let rig = makeRig()
        await rig.lifecycle.start()

        rig.lifecycle.toggleReferenceTone(stringIndex: 2, frequency: 196.0, instrument: .guitar)
        #expect(rig.lifecycle.activeToneStringIndex == 2)
        #expect(rig.lifecycle.status == .paused)
        #expect(rig.source.isStarted == false, "The tuner must not listen to its own tone")
        #expect(rig.tone.requestedTones == [.init(frequency: 196.0, stringIndex: 2, instrument: .guitar)])

        rig.tone.simulateToneEnded()
        await settled()
        #expect(rig.lifecycle.activeToneStringIndex == nil)
        #expect(rig.lifecycle.status == .listening)
        #expect(rig.source.isStarted)
    }

    @Test("Toggling the sounding String's tone stops it")
    func togglingTheSameToneStopsIt() async {
        let rig = makeRig()
        rig.lifecycle.toggleReferenceTone(stringIndex: 1, frequency: 110.0, instrument: .guitar)
        rig.lifecycle.toggleReferenceTone(stringIndex: 1, frequency: 110.0, instrument: .guitar)
        await settled()
        #expect(rig.lifecycle.activeToneStringIndex == nil)
        #expect(rig.tone.stopCount == 1)
        #expect(rig.tone.requestedTones.count == 1)
        #expect(rig.source.startCount == 0, "A tone ending does not start a tuner the player never started")
    }

    @Test("Stopping while a tone plays stays stopped when the tone ends")
    func stopDuringToneStaysStopped() async {
        let rig = makeRig()
        await rig.lifecycle.start()
        rig.lifecycle.toggleReferenceTone(stringIndex: 0, frequency: 82.41, instrument: .guitar)
        rig.lifecycle.stop()
        await settled()
        #expect(rig.lifecycle.status == .paused)
        #expect(rig.source.isStarted == false)
    }

    @Test("A resumable interruption re-arms; one still in progress does not")
    func interruptions() async {
        let rig = makeRig()
        await rig.lifecycle.start()

        rig.source.raise(.interrupted(resumable: false))
        await settled()
        #expect(rig.lifecycle.status == .interrupted)
        #expect(rig.source.isStarted == false)

        rig.source.raise(.interrupted(resumable: true))
        await settled()
        #expect(rig.lifecycle.status == .listening)
        #expect(rig.source.isStarted)
    }

    @Test("A route change re-arms on the new input")
    func routeChangeRearms() async {
        let rig = makeRig()
        await rig.lifecycle.start()
        let starts = rig.source.startCount

        rig.source.raise(.routeChanged)
        await settled()
        #expect(rig.lifecycle.status == .listening)
        #expect(rig.source.startCount == starts + 1)
    }

    @Test("A microphone event means nothing to a tuner the player paused")
    func eventsAfterStopAreIgnored() async {
        let rig = makeRig()
        await rig.lifecycle.start()
        rig.lifecycle.stop()

        rig.source.raise(.interrupted(resumable: true))
        rig.source.raise(.routeChanged)
        await settled()
        #expect(rig.lifecycle.status == .paused)
        #expect(rig.source.isStarted == false)
    }

    @Test("Capture is armed with the Tuning current at that moment, not the one at start")
    func armsWithTheCurrentTuning() async {
        let rig = makeRig()
        await rig.lifecycle.start()

        let ukulele = Tuning.resolve(
            instrument: .ukulele, tuningId: "high-g", customMidi: [], mode: .guided, a4: 440.0)
        rig.lifecycle.tuning = { ukulele }
        rig.source.raise(.routeChanged)
        await settled()

        #expect(rig.session.guidedProgress.count == ukulele.targets.count)
    }
}

import Foundation
import Observation

/// Decides whether the tuner is listening, and makes it so.
///
/// Everything that bears on that one question lives here: whether the player meant to
/// be listening, whether the microphone may be used, what an interruption or a route
/// change does to capture, and the handoff between a reference tone and the microphone
/// — a tone the tuner plays would otherwise be heard and measured by the tuner.
///
/// It drives the analysis session and reports one `status`. It knows nothing about
/// **Tunings**, preferences or what is on the display.
@MainActor
@Observable
final class ListeningLifecycle {
    /// Whether the tuner is listening, and if not, why not.
    private(set) var status: EngineStatus = .paused

    /// The **String** whose reference tone is sounding, if one is.
    private(set) var activeToneStringIndex: Int? = nil

    /// Called every time `status` is set, including to the value it already had: a
    /// restart after a route change is `.listening` again, and is still news.
    @ObservationIgnored var onStatusChange: ((EngineStatus) -> Void)?

    /// What to listen for when capture is armed. Asked at that moment rather than
    /// remembered, because capture is re-armed long after `start()` — when a tone
    /// ends, when an interruption lifts — and the player may have changed **Tuning**
    /// in between.
    @ObservationIgnored var tuning: () -> Tuning.Resolved

    /// The hardware's rate. Meaningful once `status` is `.listening`.
    var sampleRate: Double { source.sampleRate }

    @ObservationIgnored private let source: MicrophoneSource
    @ObservationIgnored private let referenceTone: ReferenceTonePlayer
    @ObservationIgnored private let session: TunerAnalysisSession

    /// Whether the player means the tuner to be listening. Not the same as whether it
    /// is: a tone or an interruption pauses capture without changing the intent, and
    /// the intent is what decides whether capture comes back afterwards.
    @ObservationIgnored private var intent = false

    /// Bumped whenever the tone situation changes, so a resume scheduled when one tone
    /// ended does not fire after another has begun.
    @ObservationIgnored private var toneGeneration: UInt64 = 0

    init(
        source: MicrophoneSource,
        referenceTone: ReferenceTonePlayer,
        session: TunerAnalysisSession,
        tuning: @escaping () -> Tuning.Resolved
    ) {
        self.source = source
        self.referenceTone = referenceTone
        self.session = session
        self.tuning = tuning

        referenceTone.onToneStarted = { [weak self] in
            Task { @MainActor [weak self] in self?.toneStarted() }
        }
        referenceTone.onToneEnded = { [weak self] in
            Task { @MainActor [weak self] in self?.toneEnded() }
        }
        session.onSourceEvent = { [weak self] event in
            self?.absorb(event)
        }
    }

    // MARK: - The player's intent

    /// The player wants the tuner listening.
    func start() async {
        intent = true
        guard status != .listening && status != .requesting else { return }
        await arm()
    }

    /// The player wants the tuner quiet.
    func stop() {
        intent = false
        stopReferenceTone()
        pause(as: .paused)
    }

    // MARK: - Reference tones

    /// Plays the reference tone of a **String**, or stops it if it is the one sounding.
    func toggleReferenceTone(stringIndex: Int, frequency: Double, instrument: InstrumentCategory) {
        if activeToneStringIndex == stringIndex {
            stopReferenceTone()
            return
        }
        toneGeneration &+= 1
        activeToneStringIndex = stringIndex
        pause(as: .paused)
        referenceTone.playString(frequency: frequency, stringIndex: stringIndex, instrument: instrument)
    }

    func stopReferenceTone() {
        guard activeToneStringIndex != nil else { return }
        toneGeneration &+= 1
        activeToneStringIndex = nil
        referenceTone.stop()
    }

    private func toneStarted() {
        toneGeneration &+= 1
        pause(as: .paused)
    }

    private func toneEnded() {
        activeToneStringIndex = nil
        guard intent else { return }
        let generation = toneGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.intent, self.toneGeneration == generation else { return }
            guard self.status != .listening && self.status != .requesting else { return }
            await self.arm()
        }
    }

    // MARK: - What the microphone reports

    /// The source's tap has already been stopped and the analysis invalidated by the
    /// time this runs. Whether the player meant to be listening decides whether the
    /// event means anything at all — a source keeps reporting after a stop, and a
    /// tuner that was deliberately paused has nothing to interrupt.
    private func absorb(_ event: MicrophoneEvent) {
        guard intent else { return }
        switch event {
        case .interrupted(let resumable):
            set(.interrupted)
            if resumable { rearm() }
        case .routeChanged:
            rearm()
        }
    }

    /// Picks capture up again after the session stopped it.
    ///
    /// Deliberately not `start()`: a route change leaves the status saying
    /// `.listening`, and `start()` guards on that status, so it would refuse to re-arm
    /// a source that the event has already stopped. The status is not evidence about
    /// the tap.
    private func rearm() {
        Task { [weak self] in
            await self?.arm()
        }
    }

    // MARK: - Arming and pausing

    /// Asks for the microphone if it has to, and starts capture.
    private func arm() async {
        switch source.permissionStatus {
        case .notDetermined:
            set(.requesting)
            guard await source.requestPermission() else {
                set(.denied)
                return
            }
        case .denied:
            set(.denied)
            return
        case .authorized:
            break
        }

        stopReferenceTone()
        let resolved = tuning()
        do {
            try session.start(source: source, config: resolved.config, targets: resolved.targets)
            set(.listening)
        } catch let error as AudioCaptureError {
            NSLog("[StrumKit] capture failed: %@", error.localizedDescription)
            switch error {
            case .noInputChannelsAvailable, .inputNodeUnavailable: pause(as: .missing)
            case .permissionDenied: pause(as: .denied)
            case .sessionActivationFailed, .engineFailed: pause(as: .failed)
            }
        } catch {
            NSLog("[StrumKit] capture failed: %@", String(describing: error))
            pause(as: .failed)
        }
    }

    /// The one teardown: the microphone and the analysis behind it stop, and the
    /// status says why.
    private func pause(as status: EngineStatus) {
        session.stop()
        set(status)
    }

    private func set(_ new: EngineStatus) {
        status = new
        onStatusChange?(new)
    }
}

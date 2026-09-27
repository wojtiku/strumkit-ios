import Foundation
@testable import StrumKit

/// A microphone that is not a microphone: it records what it was asked to do and
/// emits windows the test wrote down, so the tuner's audio lifecycle can be observed
/// without audio hardware.
final class ScriptedMicrophone: MicrophoneSource, @unchecked Sendable {
    /// Whether the microphone claims to be usable. `.denied` is the case the tuner
    /// must never start a source in.
    var permissionStatus: AudioPermissionStatus
    /// What a permission request resolves to, when one is made.
    var permissionRequestResult: Bool
    let sampleRate: Double

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isStarted = false
    private(set) var permissionRequestCount = 0

    private var deliver: (@Sendable (CapturedWindow) -> Void)?
    private let lock = NSLock()
    private var _onEvent: (@Sendable (MicrophoneEvent) -> Void)?

    var onEvent: (@Sendable (MicrophoneEvent) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onEvent
        }
        set {
            lock.lock()
            _onEvent = newValue
            lock.unlock()
        }
    }

    init(
        permissionStatus: AudioPermissionStatus = .authorized,
        permissionRequestResult: Bool = true,
        sampleRate: Double = 44_100
    ) {
        self.permissionStatus = permissionStatus
        self.permissionRequestResult = permissionRequestResult
        self.sampleRate = sampleRate
    }

    func requestPermission() async -> Bool {
        permissionRequestCount += 1
        return permissionRequestResult
    }

    func start(delivering: @escaping @Sendable (CapturedWindow) -> Void) throws {
        startCount += 1
        isStarted = true
        lock.lock()
        deliver = delivering
        lock.unlock()
    }

    func stop() {
        stopCount += 1
        isStarted = false
        lock.lock()
        deliver = nil
        lock.unlock()
    }

    /// Delivers a window the way hardware would, at whatever cadence the test likes.
    func emit(_ window: CapturedWindow) {
        lock.lock()
        let sink = deliver
        lock.unlock()
        sink?(window)
    }

    /// Reports something the microphone would report, to whoever is listening.
    ///
    /// The tuner absorbs the event on the main actor, as it must — a real session
    /// notification can arrive on the audio thread — so a test that raises an event
    /// has to suspend before asserting on what the tuner did with it.
    func raise(_ event: MicrophoneEvent) {
        lock.lock()
        let sink = _onEvent
        lock.unlock()
        sink?(event)
    }
}

/// A reference-tone player that remembers what it was asked to play and makes no
/// sound, so a test can assert *which* **String** the tuner chose.
final class RecordingReferenceTonePlayer: ReferenceTonePlayer, @unchecked Sendable {
    struct RequestedTone: Equatable, Sendable {
        let frequency: Double
        let stringIndex: Int
        let instrument: InstrumentCategory
    }

    private(set) var requestedTones: [RequestedTone] = []
    private(set) var stopCount = 0

    func playString(frequency: Double, stringIndex: Int, instrument: InstrumentCategory) {
        requestedTones.append(
            RequestedTone(frequency: frequency, stringIndex: stringIndex, instrument: instrument)
        )
    }

    func stop() {
        stopCount += 1
    }
}

/// The tuner's wiring when nothing about audio is under test: a microphone that is
/// never started and a tone player that records. Tests that *are* about the audio
/// lifecycle build their own and assert on them.
@MainActor
enum TestTuner {
    static func viewModel(
        source: MicrophoneSource = ScriptedMicrophone(),
        referenceTone: ReferenceTonePlayer = RecordingReferenceTonePlayer(),
        preferencesStore: TunerPreferencesStore = TestTuner.isolatedStore(),
        session: TunerAnalysisSession? = nil
    ) -> TunerViewModel {
        TunerViewModel(
            source: source,
            referenceTone: referenceTone,
            preferencesStore: preferencesStore,
            session: session
        )
    }

    /// A store no other test can read, so one test's saved preferences cannot decide
    /// another's resolved config.
    static func isolatedStore() -> TunerPreferencesStore {
        TunerPreferencesStore(userDefaults: UserDefaults(suiteName: "com.strumkit.tests.\(UUID().uuidString)")!)
    }
}

import AVFoundation
import Foundation

/// The device-specific `AVAudioSession` configuration for microphone capture, and
/// the notifications that report changes to it.
///
/// Behind the microphone seam. What the session is asked for — a measurement-mode
/// category so Apple's voice processing leaves the low strings alone, a 20 ms
/// preferred I/O duration, a cardioid pattern on the built-in mic — is a property of
/// the device the tuner happens to be running on, and nothing above the seam can act
/// on any of it.
///
/// The interruption and route-change observers are registered once and live as long
/// as this object, removed in `deinit`. Deliberately *not* tied to the tap's
/// lifetime: an interruption is reported whether or not a tap is installed, and the
/// notification that it *ended* — the one carrying the system's invitation to
/// resume — arrives after the tap has been stopped, because stopping the tap is
/// what the interruption caused. Unregistering on stop meant the resume could never
/// be heard, and the tuner sat at "interrupted" until the player toggled it by hand.
final class AudioSessionConfiguration: @unchecked Sendable {
    /// Reports that the system took the session away and, if it gave it back,
    /// whether it invited capture to resume.
    var onInterruption: (@Sendable (_ began: Bool, _ shouldResume: Bool) -> Void)?
    /// Reports that the input device or its route changed, so a running tap is on
    /// the wrong input.
    var onRouteChange: (@Sendable (_ reason: AVAudioSession.RouteChangeReason) -> Void)?

    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    #endif

    /// Configures and activates the shared session, and subscribes to the
    /// notifications that report changes to it.
    func activate() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            // Measurement mode disables Apple's auto-gain-control (AGC) and high-pass voice filters,
            // preserving low-frequency guitar harmonics (e.g., E2 82Hz).
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
            )
            // Evaluate 20ms analysis hops (0.020s preferred I/O duration)
            try session.setPreferredIOBufferDuration(0.020)

            // 1. Hardware Microphone Directionality: Cardioid pattern rejects off-axis room noise
            if let inputs = session.availableInputs,
               let builtInMic = inputs.first(where: { $0.portType == .builtInMic }) {
                if let dataSources = builtInMic.dataSources {
                    for source in dataSources {
                        if let supportedPatterns = source.supportedPolarPatterns,
                           supportedPatterns.contains(.cardioid) {
                            try? source.setPreferredPolarPattern(.cardioid)
                        }
                    }
                }
            }

            // Avoid forcing maximum hardware gain as a generic quiet-signal fix (Task 7 requirement).

            try session.setActive(true, options: .notifyOthersOnDeactivation)

            // Register notification observers for interruptions and route changes
            if self.interruptionObserver == nil {
                self.interruptionObserver = NotificationCenter.default.addObserver(
                    forName: AVAudioSession.interruptionNotification,
                    object: session,
                    queue: nil
                ) { [weak self] notification in
                    guard let self,
                          let userInfo = notification.userInfo,
                          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

                    switch type {
                    case .began:
                        self.onInterruption?(true, false)
                    case .ended:
                        var shouldResume = false
                        if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                            shouldResume = options.contains(.shouldResume)
                        }
                        self.onInterruption?(false, shouldResume)
                    @unknown default:
                        break
                    }
                }
            }

            if self.routeChangeObserver == nil {
                self.routeChangeObserver = NotificationCenter.default.addObserver(
                    forName: AVAudioSession.routeChangeNotification,
                    object: session,
                    queue: nil
                ) { [weak self] notification in
                    guard let self,
                          let userInfo = notification.userInfo,
                          let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

                    self.onRouteChange?(reason)
                }
            }
        } catch {
            print("[StrumKit] AVAudioSession setup failure: \(error.localizedDescription)")
            throw AudioCaptureError.sessionActivationFailed(error.localizedDescription)
        }
        #endif
    }

    /// Releases the session. Failing to is worth a log line and nothing more: the
    /// tap is already gone by the time this runs, and there is nothing to retry.
    func deactivate() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[StrumKit] Could not deactivate AVAudioSession: \(error.localizedDescription)")
        }
        #endif
    }

    #if os(iOS)
    /// Observers are registered once and live as long as this object — see the type
    /// comment for why they are not tied to the tap. They capture `self` weakly, so
    /// unregistering here is tidiness rather than correctness.
    deinit {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = routeChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }
    #endif
}

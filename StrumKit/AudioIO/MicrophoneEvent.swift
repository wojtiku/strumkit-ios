/// Something happened to the microphone that the tuner has to absorb.
public enum MicrophoneEvent: Sendable, Equatable {
    /// An interruption began, or ended. `resumable` is the system's own answer to
    /// whether capture may be picked up again: it is `false` while the interruption
    /// is in progress, and true when it ended with the system inviting a resume.
    case interrupted(resumable: Bool)
    /// The input device or its route changed, so a running tap is on the wrong input.
    case routeChanged
}

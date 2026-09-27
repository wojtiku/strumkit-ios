/// What the tuner needs from a reference tone: to make a **String** audible, and to
/// stop.
///
/// Exists so a test can assert *which* tone was requested. The synthesiser itself is
/// integration-tested against real audio hardware; the observable thing worth pinning
/// is the tuner's choice, which is otherwise only audible.
protocol ReferenceTonePlayer: AnyObject, Sendable {
    /// Plays the tone of the **String** at `frequency`, as identified by the player
    /// choosing `stringIndex` of `instrument`.
    func playString(frequency: Double, stringIndex: Int, instrument: InstrumentCategory)

    /// Stops any playing tone immediately.
    func stop()
}

import Foundation

/// The compiled-in guitar tuning and the per-string cent tolerances.
///
/// WEBTUNA.md §1.3: the engine's string order is **highest string first**, and §2.2
/// notes the web page never calls `setTuning`, so the guitar page always runs on
/// these constants. They are read out of the live engine's heap rather than
/// recomputed, and the values below are the exact float32 the engine holds
/// (`g[82..87]` in the decompile's struct layout).
///
/// `chromaticMIDI` is the grid bound `f_sk` is called with in chromatic mode
/// (`f_sk(g, 21, 83, 0, 0)` in func708), which after `f_sk`'s own base-MIDI
/// transform yields base MIDI 15 and a 75-semitone span — 1125 candidate
/// entries, up to MIDI 89.9. That resolves the caveat in WEBTUNA.md §3.5: the
/// 675-entry grid is the *guitar* grid, not a ceiling the engine is stuck at.
public struct Tuning: Sendable {
    /// Frequencies in Hz, index 0 = highest string.
    public let stringHz: [Float]
    /// Per-string in-tune tolerance in cents, same order.
    public let toleranceCents: [Float]
    /// The hard-coded MIDI table `{35, 64, 59, 55, 50, 45, 40}` (WEBTUNA.md §2.2).
    /// Only its min and max matter: they are the two arguments that bound the
    /// candidate grid.
    public let midiTable: [Int]
    /// `stringIdx` bounds: >= 0 selects a specific string, -1 is auto, -2 is
    /// chromatic, anything below -2 is rejected by the engine (§1.3).
    public let chromaticMIDI: (low: Int, high: Int)

    public static let guitar = Tuning(
        stringHz: [
            329.62756347656250,   // E4
            246.94165039062500,   // B3
            195.99769592285156,   // G3
            146.83238220214844,   // D3
            110.00000000000000,   // A2
            82.406883239746094,   // E2
        ],
        toleranceCents: [7, 7, 10, 7, 7, 12],
        midiTable: [35, 64, 59, 55, 50, 45, 40],
        chromaticMIDI: (21, 83)
    )

    /// The mode `analyseBuffer` was called with. Mirrors the `stringIdx` argument
    /// of §1.3 rather than being an enum, because the engine's own validation
    /// (`l <= -3` is an error) is part of the behaviour being ported.
    public enum Mode: Sendable, Hashable {
        case auto
        case chromatic
        case string(Int)
        /// `stringIdx < -2`, which the engine rejects.
        case unsupported(Int)

        public var isChromatic: Bool {
            if case .chromatic = self { return true }
            return false
        }

        /// The target string the engine locks onto: a specific selection wins, and
        /// auto and chromatic have no selection at all (in auto the engine picks
        /// the string nearest the detected pitch).
        public var requestedString: Int? {
            switch self {
            case .auto, .chromatic, .unsupported: return nil
            case .string(let i): return i
            }
        }
    }

    public static func mode(forStringIndex idx: Int32) -> Mode {
        if idx >= 0 { return .string(Int(idx)) }
        if idx == -1 { return .auto }
        if idx == -2 { return .chromatic }
        return .unsupported(Int(idx))
    }
}

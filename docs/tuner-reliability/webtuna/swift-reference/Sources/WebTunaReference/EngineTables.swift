import Foundation

/// The engine's two lazily-built constant tables, ported from the decompile.
///
/// Both are built in **float32**, and that is not a detail: `func511` (`f_rs`)
/// accumulates its exponent as `a += 0.5f` in float32, so the float32 rounding
/// error compounds across the 56 entries. Evaluating the same formula in Double
/// gives answers that differ from the live tables by up to 0.15 Hz, which at the
/// top of the range is a whole FFT bin. `func304` (`f_sk`) likewise stores the
/// candidate grid as float32.
///
/// Reference points: WEBTUNA.md §3.3 (filterbank), §3.5 (candidate grid), §2.2
/// (the hard-coded tuning), and the live-heap dumps in
/// `docs/tuner-reliability/webtuna/tables3.mjs` / `state2.mjs`.
public enum EngineTables {
    public static let bandCount = 56

    // MARK: - 56-band log filterbank (func511 / f_rs, WEBTUNA.md §3.3)

    /// The three 56-entry tables, in Hz.
    public struct FilterbankTables: Sendable {
        public let lower: [Float]
        public let centre: [Float]
        public let upper: [Float]
    }

    /// The two literal constants of the filterbank formula.
    ///
    /// **These are not the numbers in WEBTUNA.md §3.3.** §3.3 gives `0.046804`
    /// and `228.937714`; those reproduce the live table to only 2.5e-5 relative,
    /// which at the top of the range is a tenth of an FFT bin. The pair below
    /// reproduces all five live float32 values checked (`T_ctr[0]`, `T_lo[0]`,
    /// `T_hi[0]`, `T_ctr[55]`, `T_hi[55]`) to **7.4e-8** — float32 epsilon — and
    /// was fitted to them by golden-section search on the exponent with the scale
    /// solved from `T_ctr[0]`. The exponent is the load-bearing one: `0.046804`
    /// is a six-significant-digit rendering of `0.04680435`, and the ~7.5e-6
    /// relative error in it is most of what the reported `228.937714` is
    /// compensating for. See NOTES.md.
    public static let filterbankExponent: Float = 0.04680435
    public static let filterbankScale: Float = 228.93762

    public static let filterbank: FilterbankTables = {
        var lower = [Float](repeating: 0, count: bandCount)
        var centre = [Float](repeating: 0, count: bandCount)
        var upper = [Float](repeating: 0, count: bandCount)
        // `a` is the exponent argument, stepped by 0.5 per band. float32 on
        // purpose: this is literally what the wasm does, and the accumulation is
        // exact at this magnitude (both 0.5 and 2.318973 + 27.5 are
        // representable), so the table is a deterministic function of the two
        // constants above and nothing else.
        var a: Float = 2.318973
        for k in 0..<bandCount {
            lower[k] = (powf(10.0, max(0.0, a - 1.0) * filterbankExponent) - 1.0) * filterbankScale
            centre[k] = (powf(10.0, max(0.0, a) * filterbankExponent) - 1.0) * filterbankScale
            upper[k] = (powf(10.0, max(0.0, a + 1.0) * filterbankExponent) - 1.0) * filterbankScale
            a += 0.5
        }
        return FilterbankTables(lower: lower, centre: centre, upper: upper)
    }()

    // MARK: - candidate grid (func304 / f_sk, WEBTUNA.md §3.5)

    /// The candidate frequency grid, in Hz, ascending, at 1/15 semitone.
    public struct CandidateGrid: Sendable {
        /// Index into the grid for a MIDI note, clamped to the grid.
        public func index(forMIDINote midi: Float) -> Int {
            max(0, min(notes - 1, Int(((midi - Float(baseMIDI)) * 15.0).rounded(.down))))
        }

        /// The frequency of the nearest grid entry to a MIDI note.
        public func nearest(toMIDINote midi: Float) -> Float {
            frequencies[index(forMIDINote: midi)]
        }

        public let baseMIDI: Int
        /// The number of *semitones* spanned, not the number of entries.
        public let semitones: Int
        public var notes: Int { semitones * 15 }
        public let frequencies: [Float]
        /// MIDI value of each grid entry: `baseMIDI + d/15`.
        public let midiValues: [Float]
    }

    /// `f_sk`'s base-MIDI transform, verbatim:
    ///
    ///     base = b > 40 ? b - 14 : min(b, 32) - 6
    ///
    /// For the guitar, `b` is the low end of the hard-coded MIDI table (35) and
    /// `c` the high end (64), giving base 26 and `c - base + 7 = 45` semitones.
    public static func candidateGrid(lowMIDI: Int, highMIDI: Int) -> CandidateGrid {
        let base: Int
        if lowMIDI > 40 {
            base = lowMIDI - 14
        } else {
            base = min(lowMIDI, 32) - 6
        }
        let semitones = highMIDI - base + 7
        let count = semitones * 15
        var freqs = [Float](repeating: 0, count: count)
        var midis = [Float](repeating: 0, count: count)
        // The semitone constant is `1/12`, **not** the `0.083333f` that both
        // WEBTUNA.md and `wasm-decompile` print. Measured: `f32(1/12)` reproduces
        // the live `grid[0] = 36.7080917` to 1e-9, while `0.083333` gives
        // 36.7084618 — a 1.0e-5 relative error, which is 3.7 cents of pitch
        // error on the very first grid entry. wabt truncates float literals to
        // six significant digits, so every `0.083333f`-shaped constant in the
        // decompile is suspect; the `0.333333f` cube-root exponent is the other
        // one, and it is likewise 1/3.
        let semitone: Float = 1.0 / 12.0
        for d in 0..<count {
            // f_sk: `select_if(175.0f, d/15 + base, d/15 + base > 175.0f)`, then a
            // separate low clamp at MIDI -48 to the constant 0.510987 Hz.
            let midi = min(175.0, Float(d) / 15.0 + Float(base))
            midis[d] = midi
            if midi < -48 {
                freqs[d] = 0.510987            // the low clamp
            } else {
                freqs[d] = powf(2.0, (midi - 69.0) * semitone) * 440.0
            }
        }
        return CandidateGrid(baseMIDI: base, semitones: semitones,
                             frequencies: freqs, midiValues: midis)
    }

    /// The candidate grid for a mode. Auto and a specific string both use the
    /// compiled-in guitar tuning's MIDI bounds; only chromatic widens them.
    public static func candidateGrid(for mode: Tuning.Mode, tuning: Tuning = Tuning.guitar) -> CandidateGrid {
        if case .chromatic = mode {
            return candidateGrid(lowMIDI: tuning.chromaticMIDI.low,
                                 highMIDI: tuning.chromaticMIDI.high)
        }
        let lo = tuning.midiTable.min() ?? 35
        let hi = tuning.midiTable.max() ?? 64
        return candidateGrid(lowMIDI: lo, highMIDI: hi)
    }

    /// The per-grid-entry salience weight, from the tail of `f_sk`.
    ///
    /// A flat 1.1x boost below 165.733353 Hz, ramping linearly to 1.0 at
    /// 249.07 Hz and staying there. It is a low-frequency emphasis, not a
    /// normalisation: it is applied to the 56 salience bands before the harmonic
    /// score is formed. The live code's constants are
    /// `u = (165.733353 - midi) * 0.0012 + 1.1`, clamped to [1.0, 1.1].
    public static func gridWeight(midi: Float) -> Float {
        let u = (165.733353 - midi) * 0.0012 + 1.1
        if u < 1.0 { return 1.0 }
        if u > 1.1 { return 1.1 }
        return u
    }
}

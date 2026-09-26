import Foundation

/// Stage 6: the 56-band salience resampled onto the candidate grid, and the
/// harmonic-support score for every candidate.
///
/// WEBTUNA.md §3.5–§3.6. Two things the decompile settles that the prose does not:
///
///  * The grid is **MIDI `base` + k/15** for k = 0 … 15·semitones−1, and the
///    `base` transform is `b > 40 ? b - 14 : min(b,32) - 6`. In chromatic mode
///    `f_sk` is called with 21 and 83, which gives base MIDI 15 and 75
///    semitones — 1125 entries up to MIDI 89.9. §3.5 records the 675-entry grid
///    as if it were a ceiling; it is only the *guitar* grid.
///  * The peak is refined by a **3-point parabolic interpolation in frequency**
///    over three adjacent *grid* entries, rejected (falling back to the raw grid
///    frequency) when the vertex offset exceeds 0.5. `func708`'s test
///    `|(x[d+1]-x[d-1]) * -0.5 / ((x[d-1]+x[d+1])*0.5 - x[d])| > 0.5` is exactly
///    `|(x[d+1]-x[d-1]) / (x[d-1]-2x[d]+x[d+1])| > 0.5`.
public struct CandidateAnalysis {
    public let grid: EngineTables.CandidateGrid
    /// The salience at each grid entry.
    public let salience: [Float]
    /// Σ over harmonics of `weight(h) · max(salience over harmonic h's bins)`.
    public let score: [Float]

    public static let harmonicsPerCandidate = 20

    public init(bands residual: [Float],
                filterbank: Filterbank,
                grid: EngineTables.CandidateGrid,
                salience: inout [Float],
                score: inout [Float]) {
        self.grid = grid
        let n = grid.notes
        if salience.count != n { salience = [Float](repeating: 0, count: n) }
        if score.count != n { score = [Float](repeating: 0, count: n) }

        // --- resample the 56 band values onto the grid, linearly in bin index ---
        // Each band is anchored at round(binsPerHz · T_ctr[k]) with its residual
        // value; the destination ramps linearly to zero outside the anchor range.
        let anchors = (0..<Filterbank.bandCount).map {
            Int((filterbank.tables.centre[$0] * filterbank.binsPerHz).rounded())
        }
        let lo = anchors[0], hi = anchors[anchors.count - 1]
        var segment = 0
        for d in 0..<n {
            let f = grid.frequencies[d]
            let bin = Int(f * filterbank.binsPerHz)
            if bin < lo {
                // Ramp 0 at bin 0 up to residual[0] at the first anchor.
                salience[d] = lo > 0 ? residual[0] * Float(bin) / Float(lo) : 0
                continue
            }
            if bin > hi { salience[d] = 0; continue }
            while segment + 2 < anchors.count && anchors[segment + 1] < bin { segment += 1 }
            let b0 = anchors[segment], b1 = anchors[min(segment + 1, anchors.count - 1)]
            if b1 == b0 { salience[d] = residual[segment]; continue }
            let t = Float(bin - b0) / Float(b1 - b0)
            salience[d] = residual[segment] * (1 - t) + residual[min(segment + 1, anchors.count - 1)] * t
        }

        // The 1.0/1.1 low-frequency weight from the tail of `f_sk`: a flat 1.1x
        // boost below 165.733353 Hz ramping to 1.0 at 249.07 Hz.
        for d in 0..<n {
            salience[d] *= EngineTables.gridWeight(midi: grid.midiValues[d])
        }

        // --- harmonic-support score ---
        // For each candidate, harmonic `h` runs 1…20 while harmonic `h` is still
        // below the top analysed bin. The bin range for harmonic `h` spans the
        // half-step either side of it, and the contribution is the *maximum*
        // salience in that range times a weight that falls off with harmonic
        // frequency.
        //
        // The salience is indexed by **candidate**, but the harmonic range is
        // computed in **FFT bins**, so every bin has to be mapped through
        // `binToCandidate` first. (Using the bin directly as a candidate index is
        // the obvious mistake and it is silently wrong: the grid has 675 entries
        // and the analysed range 1136 bins, so most harmonics are simply dropped
        // and the rest score the wrong pitch. The score then peaks at the lowest
        // grid entry and the detector never locks on.)
        let msThreshold: Float = Float(FrameGeometry.realSize) * 1000.0
            / filterbank.sampleRate > 60.0 ? 52.0 : 29.0
        let topBin = filterbank.highestBin - 1

        // FFT bin -> nearest candidate-grid entry.
        var binToCandidate = [Int](repeating: 0, count: filterbank.highestBin)
        var next = 0
        for bin in 0..<filterbank.highestBin {
            let hz = filterbank.binHz * Float(bin)
            let midi = 12.0 * log2(Double(max(hz, 1e-6) / 440.0)) + 69.0
            var d = Int(((Float(midi) - Float(grid.baseMIDI)) * 15.0).rounded())
            d = max(0, min(n - 1, d))
            if d < next { d = next }
            binToCandidate[bin] = d
            next = d
        }

        for d in 0..<n {
            let f = grid.frequencies[d]
            guard f > 0 else { score[d] = 0; continue }
            let halfStep = Self.halfStep(around: d, grid: grid)
            let loF = max(1e-6, f - halfStep)
            let hiF = f + halfStep
            var total: Float = 0
            for h in 1...Self.harmonicsPerCandidate {
                // Harmonic `h` at the low edge of the half-step, in FFT bins.
                let loBinF = Float(h) * f / loF * filterbank.binsPerHz
                if !(Float(topBin) > loBinF) { break }
                let hiBinF = Float(h) * f / hiF * filterbank.binsPerHz
                let upperBin = min(filterbank.highestBin - 1, Int(loBinF))
                let lowerBin = max(0, Int(hiBinF))
                guard upperBin >= lowerBin else { continue }
                let first = binToCandidate[lowerBin]
                let last = binToCandidate[upperBin]
                guard last >= first else { continue }
                var peak: Float = 0
                for b in first...last where salience[b] > peak { peak = salience[b] }
                total += Self.harmonicWeight(harmonicHz: Float(h) * f, candidateHz: f,
                                             msThreshold: msThreshold,
                                             sampleRate: filterbank.sampleRate) * peak
            }
            score[d] = total
        }
        // `score` and `salience` are caller-owned scratch, filled in place; the
        // struct itself only carries what the decision stage needs.
        self.score = score
        self.salience = salience
    }

    /// Half the distance to the nearest neighbouring grid entry, i.e. the
    /// half-step of the 6.67-cent grid: 0.5·max(|f[d]−f[d−1]|, |f[d]−f[d+1]|).
    static func halfStep(around d: Int, grid: EngineTables.CandidateGrid) -> Float {
        let f = grid.frequencies[d]
        var m: Float = 0
        if d > 0 { m = max(m, abs(f - grid.frequencies[d - 1])) }
        if d + 1 < grid.notes { m = max(m, abs(f - grid.frequencies[d + 1])) }
        return m
    }

    /// The per-harmonic weight, verbatim from `func708`:
    ///
    ///     24.7 · ((sr/f + ms) · 0.1) / (1.4 + harmonicHz · 0.00437)
    ///
    /// `ms` is 52.0 when a frame is longer than 60 ms and 29.0 otherwise, so at
    /// 44.1 kHz it is 52.0. Note the `h` that appears is a *harmonic frequency*
    /// (`sr · b / f`), not a bin index: the decompile writes `m[3]*b/ca` where
    /// `m[3]` is the sample rate and `ca` the candidate frequency.
    static func harmonicWeight(harmonicHz: Float, candidateHz f: Float,
                               msThreshold: Float, sampleRate: Float) -> Float {
        ((sampleRate / f + msThreshold) * 0.1)
            / (harmonicHz * 4.37 / 1000.0 + 1.4) * 24.700001
    }
}

import Foundation

/// Stage 4–5: the 56-band log filterbank and the salience transform.
///
/// WEBTUNA.md §3.3–§3.4, both corrected where the prose and the decompile
/// disagree — see `DIVERGENCES.md`.
///
/// **The support is ±2 bands, not ±1.** §3.3 says "`T_lo[k] = T_ctr[k-1]`,
/// `T_hi[k] = T_ctr[k+1]`, … ±1-band triangular support". Its own formula says
/// otherwise: the exponent argument is `2.318973 + 0.5k + off`, so `off = ±1`
/// moves it by a full 1.0, i.e. **two** band steps (0.5 each). `f_rs` in the
/// decompile is unambiguous, and the live tables confirm it: `T_lo[0] = 34.9693`
/// is `T_ctr[-2]`, and `T_lo[2] == T_ctr[0] == 65.0000` exactly. The nominal
/// half-width is therefore `10^0.046804` = 1.1138 = **182.8 cents**, which is the
/// "≈183 cents" figure §3.3 quotes for effective resolution — so §3.3 is
/// internally inconsistent, and the 183 cents is the correct one.
///
/// The `(10^x - 1)` term also makes the table **non-geometric at the bottom**:
/// `T_lo[0]/T_ctr[0] = 0.538`, not `1/1.1138 = 0.898`. Band 0 is a very wide
/// triangle in cents terms, which is exactly why a 41.2 Hz bass low E is "only
/// 1.2 bands up" (§4.4).
public struct Filterbank {
    public let sampleRate: Float
    /// Hz per FFT bin: `sampleRate / complexSize`. 5.3833 Hz at 44.1 kHz.
    public let binHz: Float
    /// Bins per Hz: `complexSize / sampleRate`. The reciprocal of `binHz`, and the
    /// factor that converts a frequency in Hz into an FFT bin index.
    public let binsPerHz: Float
    public let lowestBin: Int
    public let highestBin: Int
    /// Bin index of the centre of each band, and the last bin of each triangle.
    public let centreBin: [Int]
    public let lastBin: [Int]
    public let tables: EngineTables.FilterbankTables

    public static let bandCount = EngineTables.bandCount

    /// Builds the analyser and the band loop. Deliberately initialised before
    /// anything else so `binsPerHz` is available to the bin-index computation.
    public init(sampleRate: Float) {
        self.sampleRate = sampleRate
        self.tables = EngineTables.filterbank
        self.binHz = sampleRate / Float(FrameGeometry.complexSize)
        self.binsPerHz = Float(FrameGeometry.complexSize) / sampleRate
        self.lowestBin = Int((tables.lower[0] * binsPerHz).rounded(.down)) + 1
        self.highestBin = Int((tables.upper[Filterbank.bandCount - 1] * binsPerHz).rounded(.down)) + 1

        // `trunc`, not `round`: the decompile uses i32_trunc_sat_f32_s here.
        var centres = [Int](repeating: 0, count: Filterbank.bandCount)
        var lasts = [Int](repeating: 0, count: Filterbank.bandCount)
        for k in 0..<Filterbank.bandCount {
            centres[k] = Int((tables.centre[k] * binsPerHz).rounded(.down))
            lasts[k] = Int((tables.upper[k] * binsPerHz).rounded(.down))
        }
        self.centreBin = centres
        self.lastBin = lasts
    }

    /// The 56 band values: `spectrum` must be indexed by absolute FFT bin and
    /// hold at least `highestBin` entries.
    ///
    /// Each band is a triangle in *frequency*, evaluated bin by bin:
    ///
    ///     rising:  w(b) = 1 - (centre - f(b)) / (centre - lower)   for b in [firstBin, centreBin]
    ///     falling: w(b) = 1 - (f(b) - centre) / (upper  - centre)  for b in (centreBin, lastBin]
    ///
    /// and the band value is the weighted sum. The first bin is
    /// `floor(lower * binsPerHz) + 1`; the last is `ceil(upper * binsPerHz) - 2`
    /// for a non-integral edge, which is what the decompile's
    /// `a = h + select_if(-1, 0, i) + 1` computes (see DIVERGENCES.md D3 — the
    /// top of each triangle is dropped one bin short of the nominal edge, and
    /// this port reproduces that).
    public func bands(spectrum: [Float], into out: inout [Float]) {
        if out.count != Filterbank.bandCount { out = [Float](repeating: 0, count: Filterbank.bandCount) }
        for k in 0..<Filterbank.bandCount {
            let lower = tables.lower[k]
            let centre = tables.centre[k]
            let upper = tables.upper[k]
            // A frequency in Hz becomes a bin index by multiplying by binsPerHz.
            let firstBin = Int((lower * binsPerHz).rounded(.down)) + 1
            let s = centreBin[k]
            let h = Int((upper * binsPerHz).rounded(.up))

            precondition(spectrum.count >= highestBin, "spectrum \(spectrum.count) < highestBin \(highestBin)")
            precondition(s >= 0 && s < spectrum.count, "centreBin \(s) out of range for band \(k)")
            precondition(h <= spectrum.count, "h \(h) out of range for band \(k)")
            var acc: Float = 0
            if firstBin <= s {
                let ca = 1.0 / (centre - lower)
                var bin = firstBin
                while bin <= s {
                    let f = binHz * Float(bin)
                    acc += spectrum[bin] * (1.0 - (centre - f) * ca)
                    bin += 1
                }
            }
            if h > s {
                let ca = 1.0 / (upper - centre)
                // h - 1 + 1 = h when the edge is non-integral; the decompile's
                // `ceil` indicator collapses to that. Loop runs to `a - 1`.
                let a = h
                var bin = s + 1
                while bin < a {
                    let f = binHz * Float(bin)
                    acc += spectrum[bin] * (1.0 - (f - centre) * ca)
                    bin += 1
                }
            }
            out[k] = acc
        }
    }
}

/// Stage 5: the salience transform.
///
/// WEBTUNA.md §3.4, with two corrections to the prose. See DIVERGENCES.md D2/D4.
///
/// The divisor is `1/(realFFTSize - 1)` = `1/4095`, where the decompile's `p` is
/// the **real** FFT size, not the analysed bin count. §3.4's "nBins" suggests the
/// latter; if it were, the transform would be off by a factor of 4. It does not
/// matter for the peak picking, which is scale-invariant, but it matters for
/// reproducing the arrays the engine actually holds.
///
/// And the `1.414214` multiplies the **square root**, it is not inside it:
/// `a[k] = (sqrt(m/4095) * 1.414214)^(1/3)`, which is `x^(1/6)` as §3.4 says.
/// `wasm-decompile` renders it inside the argument list, which would give
/// `sqrt(1.414214 * m/4095)` — wrong by 19 %.
///
/// The floor is `(sum of the 56 band values / 56) * 1e-4`, a ten-thousandth of
/// the mean, applied to kill dead bands.
public enum Salience {
    public static func transform(
        bands: [Float],
        realFFTSize: Int = FrameGeometry.realSize,
        compressed: inout [Float],
        residual: inout [Float]
    ) {
        let n = bands.count
        if compressed.count != n { compressed = [Float](repeating: 0, count: n) }
        if residual.count != n { residual = [Float](repeating: 0, count: n) }

        var total: Float = 0
        for v in bands { total += v }
        let floorValue = total / Float(n) * 0.0001
        let scale = 1.0 / Float(realFFTSize - 1)

        for k in 0..<n {
            let m = bands[k]
            let clamped = m > floorValue ? m : floorValue
            let a = powf((scale * clamped).squareRoot() * 1.414214, 1.0 / 3.0)
            compressed[k] = a
            residual[k] = m / a
        }
    }
}

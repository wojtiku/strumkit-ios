import Accelerate
import Foundation

/// Stage 1–3: framing geometry, the analysis window, and the FFT.
///
/// WEBTUNA.md §3.1–§3.2, confirmed against the live engine:
///
///   | Quantity                | Value                                       |
///   |-------------------------|---------------------------------------------|
///   | Real FFT size           | 4096                                        |
///   | Complex FFT size        | 8192 (zero-padded, Ooura, `nshift = 1`)      |
///   | Hop                     | 2048                                        |
///   | Frames per 4096-sample call | 2                                        |
///   | Window                  | `0.54 - 0.46*cos(2*pi*n/(N-1))`, symmetric    |
///   | Spectrum                | `|X[bin]| / 8192`, bin-major magnitude         |
///
/// The two things §3.1 does not say, both of which this port needs and both of
/// which were measured against the running module (`tools/probe-fft.mjs`):
///
///   * The spectrum is a **magnitude**, `hypot(re, im)`, not a power and not a
///     bare real part. A sine placed a quarter of a bin off centre puts almost
///     all of its energy in the imaginary part, and the engine reports the full
///     value there.
///   * The division is by exactly **8192**, the complex size, not by 4096 and not
///     by 4095. Measured as 1.220703e-4 = 1/8192 to seven figures across bins
///     8…200. This is the only place the absolute scale of the spectrum matters:
///     everything downstream is scale-invariant except `MicRms`.
///
/// The analysed bin range is *not* a constant. §3.1 states bins 7…1136 as if
/// they were chosen; they are derived from the filterbank's own edge table
/// (`floor(T_lo[0] * 8192/sr) + 1` and `floor(T_hi[55] * 8192/sr) + 1`), which is
/// why a 5-string bass low B at 30.87 Hz falls off the bottom (§4.4).
public enum FrameGeometry {
    public static let realSize = 4096
    public static let complexSize = 8192
    public static let hop = 2048
    public static let callSize = 4096
    public static let framesPerCall = callSize / hop

    /// The symmetric (not periodic) 0.54/0.46 Blackman window, `n = 0..<4096`.
    /// Verified against the live `Ooura_FFT` object's window vector to 3e-8 by
    /// `docs/tuner-reliability/webtuna/window.mjs`.
    ///
    /// Evaluated in Double over the first half and **mirrored**, so the symmetry
    /// is exact. Evaluating `cos(2*pi*n/4095)` independently at `n` and `4095-n` in
    /// float32 is only symmetric to ~6e-8 — one float32 ulp — because the two
    /// arguments round differently, and the closed form is only a float32
    /// approximation of the engine's own sin/cos polyfill anyway.
    public static let window: [Float] = {
        var w = [Float](repeating: 0, count: realSize)
        for n in 0..<(realSize / 2) {
            let v = Float(0.54 - 0.46 * cos(2.0 * Double.pi * Double(n) / Double(realSize - 1)))
            w[n] = v
            w[realSize - 1 - n] = v
        }
        return w
    }()
}

/// A reusable windowed FFT. One instance per engine, because the plans are
/// expensive relative to a 4096-sample frame.
///
/// **This is a complex FFT, not a real one, and that matters.** The engine
/// zero-pads 4096 real samples to 8192 and takes an 8192-point *complex*
/// transform, so bin *b* is at `b · sampleRate/8192` and there are 4097 bins up
/// to Nyquist. vDSP's `vDSP_fft_zrip` would be a 4096-point *real* transform,
/// whose bin *b* is at `b · sampleRate/4096` — the same frequencies would land on
/// half the bin numbers, and a 4096-point real transform cannot represent bins
/// above 2048 at all. Measured against the running module: for a tone at exactly
/// `15 · sampleRate/8192`, the engine peaks at bin 15, and so does this.
public final class SpectrumAnalyser {
    /// log2 of the complex transform size: 8192 → 13.
    private static let log2n = 13
    /// Number of usable bins: 0 … complexSize/2 inclusive.
    private static let usableBins = FrameGeometry.complexSize / 2 + 1
    /// Bins the engine's own spectrum holds as exact zeros. Measured, not derived:
    /// bins 0…5 read 0.0 and bin 6 reads 3.345e-4 for a 7-harmonic E2 tone.
    static let engineZeroedBins = 6

    public let sampleRate: Float
    /// First and last bin the filterbank reads. Derived, not hard-coded — see
    /// `FrameGeometry`'s doc comment.
    public let lowestBin: Int
    public let highestBin: Int
    /// Hz per FFT bin.
    public let binHz: Float

    private let fftSetup: FFTSetup
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private var magnitudes = [Float](repeating: 0, count: SpectrumAnalyser.usableBins)

    public init(sampleRate: Float) {
        self.sampleRate = sampleRate
        let tables = EngineTables.filterbank
        // Hz per FFT bin. A frequency in Hz becomes a bin index by dividing by this.
        self.binHz = sampleRate / Float(FrameGeometry.complexSize)
        self.lowestBin = Int((tables.lower[0] / binHz).rounded(.down)) + 1
        self.highestBin = Int((tables.upper[EngineTables.bandCount - 1] / binHz).rounded(.down)) + 1

        guard let setup = vDSP_create_fftsetup(vDSP_Length(SpectrumAnalyser.log2n),
                                               FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed for log2n=\(SpectrumAnalyser.log2n)")
        }
        self.fftSetup = setup
        self.realp = .allocate(capacity: FrameGeometry.complexSize)
        self.imagp = .allocate(capacity: FrameGeometry.complexSize)
        self.realp.initialize(repeating: 0, count: FrameGeometry.complexSize)
        self.imagp.initialize(repeating: 0, count: FrameGeometry.complexSize)
    }

    deinit {
        realp.deinitialize(count: FrameGeometry.complexSize)
        imagp.deinitialize(count: FrameGeometry.complexSize)
        realp.deallocate()
        imagp.deallocate()
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Stages 1–3 for one frame: `frame` is `realSize` samples taken from the
    /// input ring. Writes `magnitude[lowestBin ..< highestBin]` into `output`
    /// (which must hold at least `highestBin` entries) and returns the frame's
    /// spectrum RMS, `sqrt(sum(magnitude^2) / binCount)`.
    ///
    /// The RMS divisor is the *bin count* in the analysed range, not the frame
    /// size, and the sum runs over the same range the filterbank reads — which is
    /// why a DC offset, which lands in the bins below `lowestBin`, cannot move it.
    @discardableResult
    public func analyse(frame: [Float], into output: inout [Float]) -> Float {
        let n = FrameGeometry.realSize
        let window = FrameGeometry.window
        precondition(frame.count == n, "frame must be exactly \(n) samples")

        // Window into the first half; the second half stays zero. That zero-pad is
        // what makes this an 8192-point transform of 4096 samples.
        realp.update(from: frame, count: n)
        vDSP_vmul(realp, 1, window, 1, realp, 1, vDSP_Length(n))
        for i in n..<FrameGeometry.complexSize { realp[i] = 0 }
        imagp.update(repeating: 0, count: FrameGeometry.complexSize)

        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        vDSP_fft_zip(fftSetup, &split, 1, vDSP_Length(SpectrumAnalyser.log2n), FFTDirection(FFT_FORWARD))
        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(SpectrumAnalyser.usableBins))

        // The engine's normalisation: divide by the *complex* size, 8192.
        // Measured as 1.220703e-4 = 1/8192 across bins 8...200.
        var scale = Float(1.0) / Float(FrameGeometry.complexSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(SpectrumAnalyser.usableBins))

        if output.count < highestBin { output = [Float](repeating: 0, count: highestBin) }
        // The engine's spectrum has bins 0…5 identically zero and bin 6 *not*
        // zero (measured: for a 7-harmonic E2 tone, bin 6 = 3.345e-4 while bins
        // 0…5 are 0). This is a separate constant from the filterbank's
        // `lowestBin` = 7, and the difference is load bearing: bin 6 contributes
        // 3.7e-5 of the sum of squares, i.e. 1.8e-5 of the RMS, which is the whole
        // of the residual `MicRms` error if you zero one bin too many. See
        // DIVERGENCES.md D5.
        for i in 0..<Self.engineZeroedBins { output[i] = 0 }
        for i in Self.engineZeroedBins..<highestBin { output[i] = magnitudes[i] }

        // §3.8: `sqrt(Σ spectrum² / nBins)`, and `nBins` is the *top bin index*,
        // 1136 at 44.1 kHz — not the count of bins actually read (1129) and not
        // the frame size. Verified: the engine's own `spectrumRMS` equals
        // `sqrt(Σ/1136)` to the last float32 digit, whereas `Σ/1129` differs by
        // 0.3 %. See DIVERGENCES.md D5.
        var sumSquares: Float = 0
        vDSP_svesq(output, 1, &sumSquares, vDSP_Length(highestBin))
        return (sumSquares / Float(highestBin)).squareRoot()
    }
}

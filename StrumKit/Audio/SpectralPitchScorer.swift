import Foundation
import Accelerate

/// A detected local maximum of the whitened magnitude spectrum, with parabolic
/// sub-bin interpolation applied to its frequency and magnitude.
struct SpectralPeak {
    let freq: Double
    let mag: Float
}

/// What one harmonic contributed to a candidate: the position it was expected at,
/// the peaks found there, and its weighted score share.
///
/// Frequency localisation uses `peakFrequency` (unwhitened) because the
/// per-window whitening gain displaces peak positions by several cents.
/// `whitenedPeakFrequency` and `peakMagnitude` describe the whitened spectrum,
/// which is what candidate ranking and score strength are based on.
struct HarmonicEvidence: Sendable {
    let harmonic: Int
    let expectedFrequency: Double
    /// Interpolated peak position in the unwhitened spectrum; `nil` if none found.
    let peakFrequency: Double?
    /// Interpolated peak position in the whitened spectrum; `nil` if none found.
    let whitenedPeakFrequency: Double?
    let peakMagnitude: Float
    let scoreContribution: Double
}

/// A candidate pitch detected through harmonic spectral summation.
public struct SpectralCandidate: Sendable, Equatable {
    /// Measured fundamental frequency in Hertz.
    public let frequency: Double
    /// Combined harmonic score (evidence metric).
    public let score: Double
    /// Raw un-interpolated peak score on the discrete grid.
    public let rawScore: Double
    /// Peak amplitude measured for each evaluated harmonic (h = 1...H).
    public let peakHarmonics: [Float]

    public init(
        frequency: Double,
        score: Double,
        rawScore: Double,
        peakHarmonics: [Float] = []
    ) {
        self.frequency = frequency
        self.score = score
        self.rawScore = rawScore
        self.peakHarmonics = peakHarmonics
    }
}

/// Offline / sustain-recovery spectral pitch scorer implementing Klapuri 2006 harmonic summation
/// and 56-band compressive spectral whitening (sigma_b^(-2/3)).
public final class SpectralPitchScorer: @unchecked Sendable {
    public static let analysisRate: Double = 16000.0
    public static let windowSize: Int = 1536
    public static let fftSize: Int = 4096
    public static let halfFftSize: Int = 2048 // half-spectrum bins
    public static let minFrequency: Double = 50.0
    public static let maxFrequency: Double = 1100.0
    public static let gridPointsPerSemitone: Double = 15.0
    public static let maxHarmonicFrequency: Double = 6400.0
    public static let maxHarmonics: Int = 19
    public static let binResolutionHz: Double = 16000.0 / 4096.0 // 3.90625 Hz

    // MARK: - Options & Switches
    public var isWhiteningEnabled: Bool = true

    // MARK: - Precomputed Tables & Buffers
    private let lock = NSLock()
    private let fftSetup: FFTSetup
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private var hammingWindow: [Float]
    private let resampler = Resampler()

    // Whitening Precomputed Data
    private struct WhiteningBand {
        let kStart: Int
        let kEnd: Int
        let weights: [Float]
        let weightSum: Float
    }
    private let whiteningBands: [WhiteningBand]
    private let bandCentersHz: [Double]
    private struct BinGainInterpolation {
        let b0: Int
        let b1: Int
        let t: Float
    }
    private let binInterpolation: [BinGainInterpolation]

    // Candidate Grid & Harmonic Mapping
    private struct HarmonicQuery {
        let h: Int
        let weight: Float
    }
    private struct CandidateGridPoint {
        let f0: Double
        let queries: [HarmonicQuery]
    }
    private let candidateGrid: [CandidateGridPoint]

    public init() {
        let log2n = vDSP_Length(12) // 2^12 = 4096
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Failed to allocate Accelerate FFTSetup for size \(Self.fftSize)")
        }
        self.fftSetup = setup
        self.realp = .allocate(capacity: Self.halfFftSize)
        self.imagp = .allocate(capacity: Self.halfFftSize)

        // 1. Precompute Hamming window w[n] = 0.54 - 0.46 * cos(2*pi*n/(N-1))
        var window = [Float](repeating: 0, count: Self.windowSize)
        for n in 0..<Self.windowSize {
            let angle = 2.0 * Double.pi * Double(n) / Double(Self.windowSize - 1)
            window[n] = Float(0.54 - 0.46 * cos(angle))
        }
        self.hammingWindow = window

        // 2. Precompute 56 Whitening Bands from 50 Hz to 6400 Hz
        // E(f) = 21.4 * log10(1 + 0.00437 * f)
        func erbScale(_ f: Double) -> Double {
            21.4 * log10(1.0 + 0.00437 * f)
        }
        func invErbScale(_ e: Double) -> Double {
            (pow(10.0, e / 21.4) - 1.0) / 0.00437
        }

        let eMin = erbScale(50.0)
        let eMax = erbScale(6400.0)
        let numEdges = 58
        let deltaE = (eMax - eMin) / Double(numEdges - 1)
        var edgesHz = [Double](repeating: 0, count: numEdges)
        for i in 0..<numEdges {
            let e = eMin + Double(i) * deltaE
            edgesHz[i] = invErbScale(e)
        }

        let numBands = 56
        var bands = [WhiteningBand]()
        bands.reserveCapacity(numBands)
        var centers = [Double](repeating: 0, count: numBands)

        for b in 0..<numBands {
            let fLow = edgesHz[b]
            let fCenter = edgesHz[b + 1]
            let fHigh = edgesHz[b + 2]
            centers[b] = fCenter

            let kStart = max(1, Int(floor(fLow / Self.binResolutionHz)))
            let kEnd = min(Self.halfFftSize - 1, Int(ceil(fHigh / Self.binResolutionHz)))

            var weights = [Float]()
            var sum: Float = 0.0
            if kEnd >= kStart {
                weights.reserveCapacity(kEnd - kStart + 1)
                for k in kStart...kEnd {
                    let fk = Double(k) * Self.binResolutionHz
                    let h: Float
                    if fk <= fCenter {
                        h = Float((fk - fLow) / (fCenter - fLow))
                    } else {
                        h = Float((fHigh - fk) / (fHigh - fCenter))
                    }
                    let clampedH = max(0.0, h)
                    weights.append(clampedH)
                    sum += clampedH
                }
            }
            bands.append(WhiteningBand(kStart: kStart, kEnd: kEnd, weights: weights, weightSum: sum))
        }
        self.whiteningBands = bands
        self.bandCentersHz = centers

        // 3. Precompute bin gain interpolation table for all 2048 bins
        var interp = [BinGainInterpolation]()
        interp.reserveCapacity(Self.halfFftSize)
        for k in 0..<Self.halfFftSize {
            let fk = Double(k) * Self.binResolutionHz
            if fk <= centers[0] {
                interp.append(BinGainInterpolation(b0: 0, b1: 0, t: 0.0))
            } else if fk >= centers[numBands - 1] {
                interp.append(BinGainInterpolation(b0: numBands - 1, b1: numBands - 1, t: 0.0))
            } else {
                var b = 0
                while b < numBands - 2 && centers[b + 1] < fk {
                    b += 1
                }
                let c0 = centers[b]
                let c1 = centers[b + 1]
                let t = Float((fk - c0) / (c1 - c0))
                interp.append(BinGainInterpolation(b0: b, b1: b + 1, t: t))
            }
        }
        self.binInterpolation = interp

        // 4. Precompute Logarithmic Candidate Grid (50 Hz to 1100 Hz, 15 points / semitone = 180 / octave)
        let semitonesTotal = 12.0 * log2(Self.maxFrequency / Self.minFrequency)
        let numGridPoints = Int(floor(semitonesTotal * Self.gridPointsPerSemitone)) + 1
        var grid = [CandidateGridPoint]()
        grid.reserveCapacity(numGridPoints)

        for m in 0..<numGridPoints {
            let f0 = Self.minFrequency * pow(2.0, Double(m) / (12.0 * Self.gridPointsPerSemitone))
            if f0 > Self.maxFrequency { break }

            var queries = [HarmonicQuery]()
            let maxH = min(Self.maxHarmonics, Int(floor(Self.maxHarmonicFrequency / f0)))
            for h in 1...maxH {
                let hFreq = Double(h) * f0
                if hFreq > Self.maxHarmonicFrequency { break }
                let weight = Float((f0 + 52.0) / (hFreq + 320.0))
                queries.append(HarmonicQuery(h: h, weight: weight))
            }
            grid.append(CandidateGridPoint(f0: f0, queries: queries))
        }
        self.candidateGrid = grid
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        realp.deallocate()
        imagp.deallocate()
    }

    // MARK: - Public Scoring API

    /// Scores raw audio by resampling to 16 kHz if needed and applying spectral analysis.
    public func scoreAudio(samples: [Float], sampleRate: Double) -> [SpectralCandidate] {
        analyzeAudio(samples: samples, sampleRate: sampleRate)?.candidates ?? []
    }

    /// Diagnostic counterpart to `scoreAudio`: same input conditioning and
    /// scoring, but also returns the per-harmonic evidence and window statistics.
    func analyzeAudio(samples: [Float], sampleRate: Double) -> WindowAnalysis? {
        guard !samples.isEmpty else { return nil }
        if abs(sampleRate - Self.analysisRate) < 1.0 {
            return analyzeWindow(samples)
        }
        let req = AudioCaptureService.requiredInputSamples(for: sampleRate)
        let input: [Float]
        if samples.count < req {
            var padded = [Float](repeating: 0, count: req)
            let offset = req - samples.count
            for i in 0..<samples.count {
                padded[offset + i] = samples[i]
            }
            input = padded
        } else {
            input = samples
        }
        guard let resampled = resampler.resampleWindow(source: input, inputRate: sampleRate) else {
            return nil
        }
        return analyzeWindow(resampled)
    }

    /// Scores a 16 kHz window (nominally 1536 samples).
    public func scoreWindow(_ samples: [Float]) -> [SpectralCandidate] {
        analyzeWindow(samples)?.candidates ?? []
    }

    /// Full diagnostic result for one analysis window.
    struct WindowAnalysis {
        let candidates: [SpectralCandidate]
        /// Parallel to `candidates`: the harmonic evidence used to build each one.
        let evidence: [[HarmonicEvidence]]
        let rms: Double
        /// Number of local maxima admitted above the peak threshold.
        let peakCount: Int
    }

    /// Scores a window and returns candidates plus the per-harmonic evidence
    /// behind them. `scoreWindow` is the projection of this.
    func analyzeWindow(_ samples: [Float]) -> WindowAnalysis? {
        guard !samples.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        // 1. Prepare 1536 samples (truncate trailing or pad with zeros)
        var input = [Float](repeating: 0, count: Self.windowSize)
        let copyCount = min(samples.count, Self.windowSize)
        let sourceOffset = samples.count - copyCount
        for i in 0..<copyCount {
            input[i] = samples[sourceOffset + i]
        }

        // 2. Measure raw RMS and check minimum energy
        var rms: Float = 0.0
        vDSP_rmsqv(input, 1, &rms, vDSP_Length(Self.windowSize))
        guard Double(rms) >= PitchDetector.minAnalysisRMS else {
            return nil
        }
        let rawRMS = Double(rms)

        // 3. Remove DC (subtract mean)
        var mean: Float = 0.0
        vDSP_meanv(input, 1, &mean, vDSP_Length(Self.windowSize))
        var negMean = -mean
        var zeroCentered = [Float](repeating: 0, count: Self.windowSize)
        vDSP_vsadd(input, 1, &negMean, &zeroCentered, 1, vDSP_Length(Self.windowSize))

        // 4. Apply Hamming window
        var windowed = [Float](repeating: 0, count: Self.windowSize)
        vDSP_vmul(zeroCentered, 1, hammingWindow, 1, &windowed, 1, vDSP_Length(Self.windowSize))

        // 5. Zero-pad to 4096 samples
        var padded = [Float](repeating: 0, count: Self.fftSize)
        for i in 0..<Self.windowSize {
            padded[i] = windowed[i]
        }

        // 6. Compute FFT and magnitude spectrum
        let (magnitudes, powerSpectrum) = computeTransform(padded: padded)

        // 7. Whitening (if enabled)
        let Aw: [Float]
        if isWhiteningEnabled {
            Aw = applyWhitening(magnitudes: magnitudes, powerSpectrum: powerSpectrum)
        } else {
            Aw = magnitudes
        }

        // 8. Extract local spectral peaks.
        //
        // Two peak lists are built, and keeping them separate is what makes the
        // reported frequency trustworthy:
        //
        // - `whitenedPeaks` drives *ranking*. Whitening flattens the instrument's
        //   spectral envelope, which is what you want when comparing how well each
        //   candidate explains the partials.
        // - `rawPeaks` drives *localisation*. The whitening gain is recomputed from
        //   every window and varies steeply with frequency, so as a note decays the
        //   gain curve moves and displaces the apparent peak position by several
        //   cents. Reading a frequency off the whitened spectrum therefore injects
        //   a per-frame bias of up to ~10 cents.
        let whitenedPeaks = Self.extractPeaks(from: Aw, relativeThreshold: 0.005)
        let rawPeaks = Self.extractPeaks(from: magnitudes, relativeThreshold: 0.002, interpolateOnLogMagnitude: true)

        // 10. Score candidate grid
        let numPoints = candidateGrid.count
        var scores = [Float](repeating: 0, count: numPoints)
        let halfCellFactor = pow(2.0, 1.0 / 360.0) - 1.0

        for m in 0..<numPoints {
            let point = candidateGrid[m]
            var sum: Float = 0.0
            for query in point.queries {
                let hFreq = Double(query.h) * point.f0
                let radiusHz = max(Self.binResolutionHz, hFreq * halfCellFactor)

                var bestVal: Float = 0.0
                for peak in whitenedPeaks {
                    let dist = abs(peak.freq - hFreq)
                    if dist <= radiusHz {
                        let taper = 1.0 - Float(dist / (2.0 * radiusHz))
                        let val = peak.mag * taper
                        if val > bestVal { bestVal = val }
                    }
                }

                if bestVal == 0.0 {
                    let k = Int(round(hFreq / Self.binResolutionHz))
                    if k >= 1 && k < Self.halfFftSize {
                        bestVal = Aw[k] * 0.2
                    }
                }
                sum += query.weight * bestVal
            }
            scores[m] = sum
        }

        // 11. Local maxima extraction & frequency refinement
        var candidates = [SpectralCandidate]()
        var allEvidence: [[HarmonicEvidence]] = []
        candidates.reserveCapacity(32)
        allEvidence.reserveCapacity(32)

        for m in 1..<(numPoints - 1) {
            let b = scores[m]
            let a = scores[m - 1]
            let c = scores[m + 1]

            if b > a && b > c {
                let curvature = a - 2.0 * b + c
                let gridFreq: Double
                let refinedScore: Double

                if curvature < -1e-12 {
                    var delta = (a - c) / (2.0 * curvature)
                    if delta > 0.5 { delta = 0.5 }
                    if delta < -0.5 { delta = -0.5 }

                    let refinedGridIndex = Double(m) + Double(delta)
                    gridFreq = Self.minFrequency * pow(2.0, refinedGridIndex / (12.0 * Self.gridPointsPerSemitone))
                    refinedScore = Double(b - 0.25 * (a - c) * delta)
                } else {
                    gridFreq = candidateGrid[m].f0
                    refinedScore = Double(b)
                }

                // Gather the per-harmonic evidence once; it drives the reported
                // frequency and the diagnostic log alike.
                var evidence: [HarmonicEvidence] = []
                evidence.reserveCapacity(candidateGrid[m].queries.count)

                for query in candidateGrid[m].queries {
                    let hFreq = Double(query.h) * gridFreq
                    let radiusHz = max(Self.binResolutionHz, hFreq * halfCellFactor)

                    var whitenedBest: SpectralPeak?
                    for peak in whitenedPeaks {
                        guard abs(peak.freq - hFreq) <= radiusHz else { continue }
                        if whitenedBest == nil || peak.mag > whitenedBest!.mag { whitenedBest = peak }
                    }

                    // Localisation always comes from the unwhitened spectrum.
                    var rawBest: SpectralPeak?
                    for peak in rawPeaks {
                        guard abs(peak.freq - hFreq) <= radiusHz else { continue }
                        if rawBest == nil || peak.mag > rawBest!.mag { rawBest = peak }
                    }

                    evidence.append(
                        HarmonicEvidence(
                            harmonic: query.h,
                            expectedFrequency: hFreq,
                            peakFrequency: rawBest?.freq,
                            whitenedPeakFrequency: whitenedBest?.freq,
                            peakMagnitude: whitenedBest?.mag ?? 0,
                            scoreContribution: Double(query.weight) * Double(whitenedBest?.mag ?? 0)
                        )
                    )
                }

                let refined = Self.estimateFundamental(gridFrequency: gridFreq, evidence: evidence)

                candidates.append(
                    SpectralCandidate(
                        frequency: refined ?? gridFreq,
                        score: max(0.0, refinedScore),
                        rawScore: Double(b),
                        peakHarmonics: evidence.map { $0.peakMagnitude }
                    )
                )
                allEvidence.append(evidence)
            }
        }

        let paired = zip(candidates, allEvidence).sorted { $0.0.score > $1.0.score }
        return WindowAnalysis(
            candidates: paired.map { $0.0 },
            evidence: paired.map { $0.1 },
            rms: rawRMS,
            peakCount: whitenedPeaks.count
        )
    }

    // MARK: - Peak Extraction

    /// Extracts local maxima from a half-spectrum, with parabolic sub-bin
    /// interpolation of each peak's position.
    ///
    /// - Parameter relativeThreshold: peaks below `max(spectrum) * relativeThreshold`
    ///   are discarded, which bounds the cost of the later per-harmonic searches.
    /// - Parameter interpolateOnLogMagnitude: interpolates the position on the log
    ///   of the magnitude. A windowed spectral main lobe is much closer to a
    ///   Gaussian than to a parabola, so log-space interpolation is the more
    ///   accurate choice when the peak's *position* is what matters.
    static func extractPeaks(
        from spectrum: [Float],
        relativeThreshold: Float,
        interpolateOnLogMagnitude: Bool = false
    ) -> [SpectralPeak] {
        var peaks: [SpectralPeak] = []
        peaks.reserveCapacity(64)

        let floorMagnitude: Float = max(1e-12, spectrum.max() ?? 0) * relativeThreshold

        for k in 1..<(spectrum.count - 1) {
            let b = spectrum[k]
            guard b >= floorMagnitude else { continue }
            let a = spectrum[k - 1]
            let c = spectrum[k + 1]
            guard b > a, b >= c else { continue }

            let delta: Float
            let interpolatedMagnitude: Float
            if interpolateOnLogMagnitude {
                let la: Float = log(max(a, 1e-30))
                let lb: Float = log(max(b, 1e-30))
                let lc: Float = log(max(c, 1e-30))
                let curvature: Float = la - 2.0 * lb + lc
                var logDelta: Float = 0.0
                if curvature < -1e-12 {
                    let raw: Float = 0.5 * (la - lc) / curvature
                    logDelta = min(0.5, max(-0.5, raw))
                }
                delta = logDelta
                let logMag: Float = lb - 0.25 * (la - lc) * logDelta
                interpolatedMagnitude = exp(logMag)
            } else {
                let curvature: Float = a - 2.0 * b + c
                var linDelta: Float = 0.0
                if curvature < -1e-12 {
                    let raw: Float = 0.5 * (a - c) / curvature
                    linDelta = min(0.5, max(-0.5, raw))
                }
                delta = linDelta
                interpolatedMagnitude = b - 0.25 * (a - c) * linDelta
            }

            let peakBin = Double(k) + Double(delta)
            peaks.append(
                SpectralPeak(
                    freq: peakBin * binResolutionHz,
                    mag: max(b, interpolatedMagnitude)
                )
            )
        }

        return peaks
    }

    // MARK: - Fundamental Frequency Estimation

    /// Highest harmonic order used to estimate a fundamental.
    ///
    /// Real strings are slightly inharmonic (partials run sharp, increasingly so
    /// with order), so dividing a high partial's interpolated peak by its order
    /// increasingly overestimates the fundamental. Capping the order keeps that
    /// bias small while still gaining the `1/h` reduction in interpolation error.
    static let maxEstimationHarmonic: Int = 8

    /// A per-harmonic estimate may not sit further than this from the grid
    /// estimate before it is treated as a mismatched peak and discarded.
    static let maxHarmonicDeviationCents: Double = 35.0

    /// If harmonic-based estimation disagrees with the grid estimate by more than
    /// this, the grid estimate is kept: the harmonic set was not describing one
    /// fundamental and the grid maximum is the safer of the two.
    static let maxFundamentalShiftCents: Double = 45.0

    /// Estimates a candidate's fundamental from its interpolated harmonic peaks.
    ///
    /// Each harmonic `h` with a real in-window peak yields an estimate of
    /// `peak.frequency / h`. Estimates are combined with weight
    /// `peakMagnitude / h^2`, which:
    ///
    /// - divides the roughly order-independent peak-interpolation error by `h`, and
    /// - damps the *inharmonicity* bias, since a stiff string's partials run
    ///   increasingly sharp with order and `peak.frequency / h` therefore
    ///   increasingly overestimates the fundamental.
    ///
    /// The fundamental itself carries neither penalty, so a present `h = 1` peak
    /// dominates without discarding the higher partials that a weak fundamental
    /// leaves as the only evidence.
    ///
    /// - Returns: `nil` when no usable harmonic peak was found or the set does not
    ///   describe one fundamental, so the caller keeps the grid estimate.
    static func estimateFundamental(
        gridFrequency: Double,
        evidence: [HarmonicEvidence]
    ) -> Double? {
        guard gridFrequency > 0 else { return nil }

        var weightedSum: Double = 0.0
        var weightTotal: Double = 0.0

        for item in evidence {
            guard item.harmonic <= maxEstimationHarmonic else { continue }
            guard let peakFrequency = item.peakFrequency, item.peakMagnitude > 0 else { continue }

            let h = Double(item.harmonic)
            let estimate = peakFrequency / h
            guard estimate > 0, estimate.isFinite else { continue }

            // Reject peaks that do not plausibly belong to this fundamental.
            let deviation = abs(1200.0 * log2(estimate / gridFrequency))
            guard deviation <= maxHarmonicDeviationCents else { continue }

            let weight = Double(item.peakMagnitude) / (h * h)
            weightedSum += weight * estimate
            weightTotal += weight
        }

        guard weightTotal > 0 else { return nil }

        let estimate = weightedSum / weightTotal
        guard estimate.isFinite, estimate > 0 else { return nil }

        // Reject the whole harmonic set if it describes a different fundamental.
        let shift = abs(1200.0 * log2(estimate / gridFrequency))
        guard shift <= maxFundamentalShiftCents else { return nil }

        return estimate
    }

    // MARK: - Internal Transform & Diagnostic Seams
    internal func computeTransform(padded: [Float]) -> (magnitudes: [Float], powerSpectrum: [Float]) {        padded.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            for i in 0..<Self.halfFftSize {
                realp[i] = base[2 * i]
                imagp[i] = base[2 * i + 1]
            }
        }

        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        vDSP_fft_zrip(fftSetup, &split, 1, vDSP_Length(12), FFTDirection(FFT_FORWARD))

        var powerSpectrum = [Float](repeating: 0, count: Self.halfFftSize)
        vDSP_zvmags(&split, 1, &powerSpectrum, 1, vDSP_Length(Self.halfFftSize))

        var scale: Float = 0.25
        vDSP_vsmul(powerSpectrum, 1, &scale, &powerSpectrum, 1, vDSP_Length(Self.halfFftSize))

        var magnitudes = [Float](repeating: 0, count: Self.halfFftSize)
        var count = Int32(Self.halfFftSize)
        vvsqrtf(&magnitudes, powerSpectrum, &count)
        magnitudes[0] = 0.0

        return (magnitudes, powerSpectrum)
    }

    /// Computes unwhitened DFT magnitude spectrum A[k] for the input window.
    public func computeMagnitudes(samples: [Float]) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        var input = [Float](repeating: 0, count: Self.windowSize)
        let copyCount = min(samples.count, Self.windowSize)
        let sourceOffset = samples.count - copyCount
        for i in 0..<copyCount {
            input[i] = samples[sourceOffset + i]
        }

        var mean: Float = 0.0
        vDSP_meanv(input, 1, &mean, vDSP_Length(Self.windowSize))
        var negMean = -mean
        var zeroCentered = [Float](repeating: 0, count: Self.windowSize)
        vDSP_vsadd(input, 1, &negMean, &zeroCentered, 1, vDSP_Length(Self.windowSize))

        var windowed = [Float](repeating: 0, count: Self.windowSize)
        vDSP_vmul(zeroCentered, 1, hammingWindow, 1, &windowed, 1, vDSP_Length(Self.windowSize))

        var padded = [Float](repeating: 0, count: Self.fftSize)
        for i in 0..<Self.windowSize {
            padded[i] = windowed[i]
        }

        let (mags, _) = computeTransform(padded: padded)
        return mags
    }

    // MARK: - Whitening Implementation
    private func applyWhitening(magnitudes: [Float], powerSpectrum: [Float]) -> [Float] {
        let numBands = whiteningBands.count
        var sigma = [Float](repeating: 0, count: numBands)
        var maxSigma: Float = 0.0

        for b in 0..<numBands {
            let band = whiteningBands[b]
            guard band.weightSum > 1e-12 else { continue }

            var weightedPowerSum: Float = 0.0
            for (idx, k) in (band.kStart...band.kEnd).enumerated() {
                weightedPowerSum += band.weights[idx] * powerSpectrum[k]
            }
            let s = sqrt(weightedPowerSum / band.weightSum)
            sigma[b] = s
            if s > maxSigma { maxSigma = s }
        }

        let floorSigma = max(1e-6, 0.02 * maxSigma)
        let epsilon = max(1e-12, 1e-4 * maxSigma)
        var gains = [Float](repeating: 1.0, count: numBands)
        var activeGains = [Float]()
        activeGains.reserveCapacity(numBands)

        for b in 0..<numBands {
            let s = max(sigma[b], Float(epsilon))
            let g = pow(s, -2.0 / 3.0)
            gains[b] = g
            if sigma[b] >= Float(floorSigma) {
                activeGains.append(g)
            }
        }

        // Use median of active bands if available, otherwise median of all
        let normRefGain: Float
        if !activeGains.isEmpty {
            activeGains.sort()
            normRefGain = activeGains[activeGains.count / 2]
        } else {
            var sortedGains = gains
            sortedGains.sort()
            normRefGain = sortedGains[numBands / 2]
        }
        let safeMedian = max(1e-12, normRefGain)

        // Interpolate and clamp gains to [0.1, 10.0]
        var Aw = [Float](repeating: 0, count: Self.halfFftSize)
        for k in 1..<Self.halfFftSize {
            let interp = binInterpolation[k]
            let rawGain = (1.0 - interp.t) * gains[interp.b0] + interp.t * gains[interp.b1]
            var normGain = rawGain / safeMedian
            if normGain < 0.1 { normGain = 0.1 }
            if normGain > 10.0 { normGain = 10.0 }
            Aw[k] = magnitudes[k] * normGain
        }

        return Aw
    }

    // MARK: - Direct DFT Diagnostic Seam
    /// Computes the exact Discrete Fourier Transform magnitude for verification against Accelerate FFT.
    public static func directDFT(samples: [Float], fftSize: Int) -> [Float] {
        let halfSize = fftSize / 2
        var magnitudes = [Float](repeating: 0, count: halfSize)
        let n = samples.count

        for k in 0..<halfSize {
            var re: Double = 0.0
            var im: Double = 0.0
            for i in 0..<n {
                let angle = 2.0 * Double.pi * Double(k * i) / Double(fftSize)
                let s = Double(samples[i])
                re += s * cos(angle)
                im -= s * sin(angle)
            }
            magnitudes[k] = Float(sqrt(re * re + im * im))
        }
        return magnitudes
    }
}

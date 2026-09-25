import Foundation
import Accelerate

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
    public var isScoringEnabled: Bool = true

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
        guard !samples.isEmpty else { return [] }
        if abs(sampleRate - Self.analysisRate) < 1.0 {
            return scoreWindow(samples)
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
            return []
        }
        return scoreWindow(resampled)
    }

    /// Scores a 16 kHz window (nominally 1536 samples).
    public func scoreWindow(_ samples: [Float]) -> [SpectralCandidate] {
        guard isScoringEnabled, !samples.isEmpty else { return [] }

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
            return []
        }

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

        // 8. Whitening (if enabled)
        let Aw: [Float]
        if isWhiteningEnabled {
            Aw = applyWhitening(magnitudes: magnitudes, powerSpectrum: powerSpectrum)
        } else {
            Aw = magnitudes
        }

        // 9. Extract local spectral peaks from Aw
        struct SpectralPeak {
            let freq: Double
            let mag: Float
        }
        var spectralPeaks = [SpectralPeak]()
        spectralPeaks.reserveCapacity(64)
        let minPeakMag: Float = max(1e-6, (Aw.max() ?? 0) * 0.005)

        for k in 1..<(Self.halfFftSize - 1) {
            let b = Aw[k]
            guard b >= minPeakMag else { continue }
            let a = Aw[k - 1]
            let c = Aw[k + 1]
            if b > a && b >= c {
                let curv = a - 2.0 * b + c
                let delta = (curv < -1e-12) ? min(0.5, max(-0.5, (a - c) / (2.0 * curv))) : 0.0
                let peakBin = Double(k) + Double(delta)
                let peakFreq = peakBin * Self.binResolutionHz
                let peakMag = b - 0.25 * (a - c) * delta
                spectralPeaks.append(SpectralPeak(freq: peakFreq, mag: max(b, peakMag)))
            }
        }

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
                for peak in spectralPeaks {
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

        // 11. Local maxima extraction & parabolic refinement
        var candidates = [SpectralCandidate]()
        candidates.reserveCapacity(32)

        for m in 1..<(numPoints - 1) {
            let b = scores[m]
            let a = scores[m - 1]
            let c = scores[m + 1]

            if b > a && b > c {
                let curvature = a - 2.0 * b + c
                let refinedFreq: Double
                let refinedScore: Double

                if curvature < -1e-12 {
                    var delta = (a - c) / (2.0 * curvature)
                    if delta > 0.5 { delta = 0.5 }
                    if delta < -0.5 { delta = -0.5 }

                    let refinedGridIndex = Double(m) + Double(delta)
                    refinedFreq = Self.minFrequency * pow(2.0, refinedGridIndex / (12.0 * Self.gridPointsPerSemitone))
                    refinedScore = Double(b - 0.25 * (a - c) * delta)
                } else {
                    refinedFreq = candidateGrid[m].f0
                    refinedScore = Double(b)
                }

                // Collect diagnostic peak amplitudes for the candidate
                let peaks = candidateGrid[m].queries.map { query -> Float in
                    let hFreq = Double(query.h) * candidateGrid[m].f0
                    let radiusHz = max(Self.binResolutionHz, hFreq * halfCellFactor)
                    var best: Float = 0.0
                    for peak in spectralPeaks {
                        if abs(peak.freq - hFreq) <= radiusHz {
                            if peak.mag > best { best = peak.mag }
                        }
                    }
                    return best
                }

                candidates.append(
                    SpectralCandidate(
                        frequency: refinedFreq,
                        score: max(0.0, refinedScore),
                        rawScore: Double(b),
                        peakHarmonics: peaks
                    )
                )
            }
        }

        candidates.sort { $0.score > $1.score }
        return candidates
    }

    // MARK: - Internal Transform & Diagnostic Seams
    internal func computeTransform(padded: [Float]) -> (magnitudes: [Float], powerSpectrum: [Float]) {
        padded.withUnsafeBufferPointer { buffer in
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

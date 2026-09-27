import Foundation

/// Polyphase sinc resampler matching chorder's trailing-window resampling.
/// Resamples arbitrary input sample rate (e.g. 44.1kHz, 48kHz) down to ANALYSIS_RATE = 16000Hz.
public final class Resampler: @unchecked Sendable {
    public static let analysisRate: Double = 16000.0
    public static let windowSize: Int = 1536
    public static let resamplerRadius: Int = 48
    public static let resamplerPhases: Int = 256

    private var cachedKernels: [Int: [[Float]]] = [:]
    private let lock = NSLock()

    public init() {}

    /// Trailing input samples needed to resample a window at `sampleRate` down to
    /// `analysisRate`.
    ///
    /// How much history the polyphase sinc filter has to reach back over, plus one
    /// full output window at the input rate. Lives here rather than at the audio
    /// edge: it is a property of the filter, and every caller of it — the capture
    /// tap, the spectral scorer, the replay helpers — is asking the same question.
    public static func requiredInputSamples(for sampleRate: Double) -> Int {
        if sampleRate <= analysisRate {
            return windowSize
        }
        let ratio = sampleRate / analysisRate
        return Int(ceil(Double(2 * resamplerRadius + 1) + Double(windowSize - 1) * ratio))
    }

    /// Calculates or retrieves precomputed polyphase sinc filter coefficients for a given sample rate.
    private func getCoefficients(for rate: Double) -> [[Float]] {
        let roundedRate = Int(round(rate))
        lock.lock()
        defer { lock.unlock() }

        if let existing = cachedKernels[roundedRate] {
            return existing
        }

        let cutoff = min(0.45, 6400.0 / rate)
        var phases = [[Float]](repeating: [Float](repeating: 0.0, count: Self.resamplerRadius * 2 + 1), count: Self.resamplerPhases)

        for phase in 0..<Self.resamplerPhases {
            var sum: Float = 0.0
            for k in -Self.resamplerRadius...Self.resamplerRadius {
                let offset = Double(k) - Double(phase) / Double(Self.resamplerPhases)
                let sinc: Double
                if abs(offset) < 1e-8 {
                    sinc = 2.0 * cutoff
                } else {
                    sinc = sin(2.0 * Double.pi * cutoff * offset) / (Double.pi * offset)
                }
                let kDouble = Double(k)
                let radiusDouble = Double(Self.resamplerRadius)
                let window = 0.42 + 0.5 * cos(Double.pi * kDouble / radiusDouble) + 0.08 * cos(2.0 * Double.pi * kDouble / radiusDouble)
                let val = Float(sinc * window)
                phases[phase][k + Self.resamplerRadius] = val
                sum += val
            }

            if sum > 0 {
                for k in 0..<phases[phase].count {
                    phases[phase][k] /= sum
                }
            }
        }

        cachedKernels[roundedRate] = phases
        return phases
    }

    /// Resamples the trailing window of `source` to `windowSize` samples at 16000 Hz.
    public func resampleWindow(source: [Float], inputRate: Double) -> [Float]? {
        let count = source.count
        guard count >= Self.windowSize else { return nil }

        if abs(inputRate - Self.analysisRate) < 1.0 {
            let start = count - Self.windowSize
            return Array(source[start..<count])
        }

        let ratio = inputRate / Self.analysisRate
        let end = Double(count - 1 - Self.resamplerRadius)
        let start = end - Double(Self.windowSize - 1) * ratio

        guard inputRate >= Self.analysisRate && start >= Double(Self.resamplerRadius) else {
            return nil
        }

        let filters = getCoefficients(for: inputRate)
        var output = [Float](repeating: 0.0, count: Self.windowSize)

        for i in 0..<Self.windowSize {
            let position = start + Double(i) * ratio
            let center = Int(floor(position))
            let phaseFrac = position - Double(center)
            let phaseIdx = min(Self.resamplerPhases - 1, Int(floor(phaseFrac * Double(Self.resamplerPhases))))
            let filter = filters[phaseIdx]

            var value: Float = 0.0
            for k in -Self.resamplerRadius...Self.resamplerRadius {
                let sampleIdx = center + k
                if sampleIdx >= 0 && sampleIdx < count {
                    value += source[sampleIdx] * filter[k + Self.resamplerRadius]
                }
            }
            output[i] = value
        }

        return output
    }
}

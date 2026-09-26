import Foundation

/// The 7-harmonic reference tone from `iso.mjs`, ported so the stage tests drive
/// the Swift engine and the wasm harness with identical samples.
///
/// `iso.mjs`:
///
///     export const H = [1, 0.5, 0.33, 0.25, 0.2, 0.16, 0.13];
///     export function tone(freq, sr = 44100, n = 4096, harm = H, noise = 0, dc = 0) {
///       ... o[i] = s * 0.2 + dc;
///     }
///     export const NOTE = (m) => 440 * Math.pow(2, (m - 69) / 12);
public enum ReferenceTone {
    public static let harmonics = [1.0, 0.5, 0.33, 0.25, 0.2, 0.16, 0.13]

    public static func note(_ midi: Double) -> Double { 440.0 * pow(2.0, (midi - 69.0) / 12.0) }

    public static func samples(frequency: Double,
                               sampleRate: Double = 44_100,
                               count: Int = 4096,
                               harmonics: [Double] = ReferenceTone.harmonics,
                               dc: Double = 0) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var s = 0.0
            for (k, h) in harmonics.enumerated() {
                let f = frequency * Double(k + 1)
                if f < sampleRate / 2 { s += h * sin(2.0 * Double.pi * f * Double(i) / sampleRate) }
            }
            out[i] = Float(s * 0.2 + dc)
        }
        return out
    }
}

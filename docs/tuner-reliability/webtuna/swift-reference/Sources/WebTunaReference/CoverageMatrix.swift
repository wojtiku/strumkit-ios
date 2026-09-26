import Foundation

// CoverageMatrix — the signal manifest, and the bit-exact signal generator.
//
// This is a port of `xeng.mjs`'s `buildSignal` in
// docs/tuner-reliability/webtuna/xeng.mjs, which in turn mirrors
// `CoverageMatrix.signal` in StrumKitTests. The port exists so that the Swift
// reference engine and the WebTuna oracle can be fed *provably identical*
// samples; that claim is only as good as this generator, which is why every
// cell carries an FNV-1a checksum of its own samples and the conformance test
// asserts on it.
//
// Bit-exactness rules, all of which come from the JavaScript and are load
// bearing:
//   * `Math.sin` / `Math.exp` are computed in Double.
//   * Every store into the Float32Array rounds to Float32, and there are three
//     separate rounding points (envelope write, noise add, final scale). JS
//     rounds on assignment; so does `Float(...)` here.
//   * `Math.round` in JS rounds .5 toward +Infinity; Swift's `rounded()` breaks
//     ties away from zero. They differ only on an exact .5 and rate*seconds is
//     exact, so either is fine — this uses `rounded()` to match the Swift
//     original.
//   * The noise LCG is evaluated in Double. The state is below 2^31 from the
//     first step and every product is below 2^47, so Double is exact here and
//     Swift's `&*` cannot diverge from JS `%`.

public struct CoverageCell: Decodable, Sendable {
    public let label: String
    public let noteHz: Double
    public let truthHz: Double
    public let amplitude: Double
    public let attackSeconds: Double
    public let decayTau: Double
    /// `[h1, h2, h3, h4]` — only four harmonics, unlike the 7-harmonic `tone()`
    /// in `iso.mjs`.
    public let h1: Double
    public let h2: Double
    public let h3: Double
    public let h4: Double
    public let inharmonicity: Double
    /// `"clean"` for no noise, otherwise the SNR in dB.
    public let snrDB: DoubleOrClean
    public let seed: UInt64
    /// `analyseBuffer`'s `stringIdx` argument: -1 auto, -2 chromatic, >= 0 a
    /// specific string. Decided on the StrumKit side from the cell's instrument,
    /// not re-derived here.
    public let idx: Int32
    public let extraFrequencies: [Double]

    public enum DoubleOrClean: Decodable, Sendable {
        case clean
        case decibels(Double)

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self), s == "clean" { self = .clean; return }
            self = .decibels(try c.decode(Double.self))
        }
    }

    public var harmonicWeights: [Double] { [h1, h2, h3, h4] }
}

public enum CoverageMatrix {
    public static let sampleRate = 44_100.0
    public static let seconds = 3.0
    /// Must equal `EXTRA_VOICE_WEIGHT` in `xeng.mjs` and
    /// `CoverageMatrix.extraVoiceWeight` in StrumKitTests, or the poly- cells'
    /// checksums diverge and the whole comparison is void.
    public static let extraVoiceWeight = 0.7

    public static func cells() throws -> [CoverageCell] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WebTunaReference
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // swift-reference
            .appendingPathComponent("Fixtures/xcells.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([CoverageCell].self, from: data)
    }

    /// Port of `buildSignal` in `xeng.mjs`. See the type comment for the rules.
    public static func signal(for cell: CoverageCell,
                              rate: Double = sampleRate,
                              seconds: Double = CoverageMatrix.seconds) -> [Float] {
        let n = Int((rate * seconds).rounded())
        var out = [Float](repeating: 0, count: n)
        let weights = cell.harmonicWeights
        var peak = 0.0
        let twoPi = 2.0 * Double.pi

        for i in 0..<n {
            let t = Double(i) / rate
            var sum = 0.0
            for k in 0..<4 {
                let w = weights[k]
                if w == 0 { continue }                       // JS: `where w != 0`
                let nd = Double(k + 1)
                let fn = nd * cell.truthHz * (1.0 + cell.inharmonicity * nd * nd).squareRoot()
                if fn >= rate / 2 { continue }               // JS: `guard fn < rate/2`
                let phase = twoPi * fn * t + 0.4 * Double(k)
                sum += w * sin(phase)
            }
            for f in cell.extraFrequencies where f < rate / 2 {
                sum += extraVoiceWeight * sin(twoPi * f * t)
            }
            let attack = min(1.0, t / max(cell.attackSeconds, 1e-6))
            let envelope = attack * exp(-t / cell.decayTau)
            let v = cell.amplitude * envelope * sum
            out[i] = Float(v)                               // float32 store #1
            peak = max(peak, abs(v))
        }

        if case .clean = cell.snrDB { return out }
        guard case .decibels(let snrDB) = cell.snrDB else { return out }

        let scale = cell.amplitude / peak
        var sumSq = 0.0
        for v in out { sumSq += Double(v) * Double(v) }
        let signalPower = sumSq / Double(out.count)
        let noiseAmplitude = signalPower.squareRoot() * pow(10.0, -snrDB / 20.0) * (3.0).squareRoot()

        // JS: `lcg = (lcg * 48271) % 2147483647`, seeded with 1 if seed == 0.
        // The state stays below 2^31 and each product below 2^47, so plain Double
        // arithmetic is exact and `%` and `&*` agree.
        var lcg = cell.seed == 0 ? 1.0 : Double(cell.seed)
        for i in 0..<n {
            lcg = (lcg * 48271.0).truncatingRemainder(dividingBy: 2147483647.0)
            let u = (lcg / 2147483647.0) * 2.0 - 1.0
            out[i] = Float(Double(out[i]) + noiseAmplitude * u)   // float32 store #2
        }
        for i in 0..<n {
            // JS: `out[i] *= scale`, where `out[i]` is a Float32Array element and
            // `scale` a double. JS promotes both to double, multiplies, and rounds
            // once on the store. `out[i] *= Float(scale)` would round `scale` first
            // and then multiply in float32 — a double rounding, and a different one
            // per cell. This is why the four noisy cells' checksums did not match.
            out[i] = Float(Double(out[i]) * scale)             // float32 store #3
        }
        return out
    }
}

/// FNV-1a, 32-bit, over the raw little-endian bytes of the samples. Byte-for-byte
/// the same function as `fnv1a32` in `xeng.mjs` and in the StrumKit emitter, and
/// for the same reason: if the two sides disagree, they were fed different audio
/// and every number downstream is void.
public enum FNV1a {
    public static func hash32(_ samples: [Float]) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for s in samples {
            let bits = s.bitPattern.littleEndian
            withUnsafeBytes(of: bits) { raw in
                for b in raw {
                    h ^= UInt32(b)
                    h = h &* 16_777_619
                }
            }
        }
        return h
    }

    public static func hex32(_ v: UInt32) -> String {
        let s = String(v, radix: 16)
        return String(repeating: "0", count: max(0, 8 - s.count)) + s
    }
}

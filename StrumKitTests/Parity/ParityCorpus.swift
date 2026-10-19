// StrumKitTests/Parity/ParityCorpus.swift
import Foundation
import CryptoKit
@testable import StrumKit

public struct ParityTestCase: Sendable {
    public var name: String
    public var category: String
    public var description: String
    public var sampleRate: Double
    public var samples: [Float]
    public var tuning: String
    public var auto: Bool
    public var customFrames: [ParityCustomFrame]?

    public init(
        name: String,
        category: String,
        description: String,
        sampleRate: Double,
        samples: [Float],
        tuning: String = "standard",
        auto: Bool = true,
        customFrames: [ParityCustomFrame]? = nil
    ) {
        self.name = name
        self.category = category
        self.description = description
        self.sampleRate = sampleRate
        self.samples = samples
        self.tuning = tuning
        self.auto = auto
        self.customFrames = customFrames
    }
}

// MARK: - WAV Parser

public enum ParityWavParser {
    public enum WavError: Error, CustomStringConvertible {
        case fileNotFound(String)
        case invalidHeader(String)
        case unsupportedFormat(String)

        public var description: String {
            switch self {
            case .fileNotFound(let path): return "WAV file not found: \(path)"
            case .invalidHeader(let msg): return "Invalid WAV header: \(msg)"
            case .unsupportedFormat(let msg): return "Unsupported WAV format: \(msg)"
            }
        }
    }

    private struct Chunk {
        let id: String
        let start: Int
        let size: Int
    }

    private static func readUInt32LE(data: Data, offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt16LE(data: Data, offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) |
            (UInt16(data[offset + 1]) << 8)
    }

    private static func readInt16LE(data: Data, offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16LE(data: data, offset: offset))
    }

    private static func readInt32LE(data: Data, offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32LE(data: data, offset: offset))
    }

    public static func parse(data: Data) throws -> (samples: [Float], sampleRate: Double) {
        guard data.count >= 12 else {
            throw WavError.invalidHeader("File too short (\(data.count) bytes)")
        }

        let riff = String(decoding: data[0..<4], as: UTF8.self)
        guard riff == "RIFF" else {
            throw WavError.invalidHeader("Missing RIFF header, found \(riff)")
        }

        let wave = String(decoding: data[8..<12], as: UTF8.self)
        guard wave == "WAVE" else {
            throw WavError.invalidHeader("RIFF container is not WAVE, found \(wave)")
        }

        var formatTag: Int = 0
        var channels: Int = 0
        var sampleRate: Double = 0
        var blockAlign: Int = 0
        var bits: Int = 0
        var hasFmt = false
        var dataChunk: Chunk? = nil

        var offset = 12
        while offset + 8 <= data.count {
            let chunkId = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let chunkSize = Int(readUInt32LE(data: data, offset: offset + 4))
            let start = offset + 8
            let available = max(0, data.count - start)
            let clamped = (chunkSize < 0 || chunkSize > available) ? available : chunkSize

            if chunkId == "fmt " {
                guard clamped >= 16 else {
                    throw WavError.invalidHeader("fmt chunk too small (\(clamped) bytes)")
                }
                formatTag = Int(readUInt16LE(data: data, offset: start))
                channels = Int(readUInt16LE(data: data, offset: start + 2))
                sampleRate = Double(readUInt32LE(data: data, offset: start + 4))
                blockAlign = Int(readUInt16LE(data: data, offset: start + 12))
                bits = Int(readUInt16LE(data: data, offset: start + 14))

                if formatTag == 0xFFFE { // WAVE_FORMAT_EXTENSIBLE
                    guard clamped >= 40 else {
                        throw WavError.invalidHeader("EXTENSIBLE fmt chunk is \(clamped) bytes, need 40")
                    }
                    let subFormat = Int(readUInt32LE(data: data, offset: start + 24))
                    if subFormat == 1 {
                        formatTag = 1 // PCM
                    } else if subFormat == 3 {
                        formatTag = 3 // IEEE_FLOAT
                    } else {
                        throw WavError.unsupportedFormat("Unsupported EXTENSIBLE SubFormat \(subFormat)")
                    }
                }
                hasFmt = true
            } else if chunkId == "data" && dataChunk == nil {
                dataChunk = Chunk(id: chunkId, start: start, size: clamped)
            }

            offset = start + clamped + (clamped & 1)
        }

        guard hasFmt else { throw WavError.invalidHeader("No fmt chunk found") }
        guard let dataChunk = dataChunk else { throw WavError.invalidHeader("No data chunk found") }
        guard channels > 0 else { throw WavError.invalidHeader("Channels declared 0") }
        guard sampleRate > 0 else { throw WavError.invalidHeader("Sample rate declared 0") }

        let bytesPerSample = bits / 8
        let align = blockAlign > 0 ? blockAlign : bytesPerSample * channels
        let frameCount = dataChunk.size / align

        var samples = [Float](repeating: 0.0, count: frameCount)
        let invChannels = 1.0 / Double(channels)

        for frame in 0..<frameCount {
            var mix: Double = 0.0
            for ch in 0..<channels {
                let at = dataChunk.start + frame * align + ch * bytesPerSample
                let val: Double
                if formatTag == 1 { // PCM
                    if bits == 16 {
                        val = Double(readInt16LE(data: data, offset: at)) / 32768.0
                    } else if bits == 24 {
                        let b0 = UInt32(data[at])
                        let b1 = UInt32(data[at + 1]) << 8
                        let b2 = UInt32(data[at + 2]) << 16
                        var raw = Int32(bitPattern: b0 | b1 | b2)
                        if (raw & 0x800000) != 0 {
                            raw |= ~0xFFFFFF
                        }
                        val = Double(raw) / 8388608.0
                    } else if bits == 32 {
                        val = Double(readInt32LE(data: data, offset: at)) / 2147483648.0
                    } else {
                        throw WavError.unsupportedFormat("PCM bits \(bits) unsupported")
                    }
                } else if formatTag == 3 { // IEEE Float
                    if bits == 32 {
                        let u = readUInt32LE(data: data, offset: at)
                        val = Double(Float(bitPattern: u))
                    } else if bits == 64 {
                        let u0 = UInt64(readUInt32LE(data: data, offset: at))
                        let u1 = UInt64(readUInt32LE(data: data, offset: at + 4)) << 32
                        val = Double(bitPattern: u0 | u1)
                    } else {
                        throw WavError.unsupportedFormat("Float bits \(bits) unsupported")
                    }
                } else {
                    throw WavError.unsupportedFormat("Format tag \(formatTag) unsupported")
                }
                mix += val
            }
            samples[frame] = Float(mix * invChannels)
        }

        return (samples, sampleRate)
    }
}

// MARK: - Corpus Generator

public enum ParityCorpus {
    public struct Tone {
        public var note: String?
        public var seconds: Double
        public var cents: Double?
        public var amplitude: Double?
        public var noise: Double?
        public var wobble: Bool?
        public var harmonics: [Double]?
        public var decayTau: Double?

        public init(
            note: String? = nil,
            seconds: Double,
            cents: Double? = nil,
            amplitude: Double? = nil,
            noise: Double? = nil,
            wobble: Bool? = nil,
            harmonics: [Double]? = nil,
            decayTau: Double? = nil
        ) {
            self.note = note
            self.seconds = seconds
            self.cents = cents
            self.amplitude = amplitude
            self.noise = noise
            self.wobble = wobble
            self.harmonics = harmonics
            self.decayTau = decayTau
        }
    }

    public static func makeControlledCase(name: String, rate: Double, tones: [Tone]) -> [Float] {
        var samples: [Float] = []
        var phase: Double = 0.0
        var seed: UInt32 = 731
        let standardTunings: [String: Double] = [
            "G4": 440.0 * pow(2.0, -2.0 / 12.0),
            "C4": 440.0 * pow(2.0, -9.0 / 12.0),
            "E4": 440.0 * pow(2.0, -5.0 / 12.0),
            "A4": 440.0
        ]

        for tone in tones {
            let frequency: Double?
            if let note = tone.note, let baseFreq = standardTunings[note] {
                frequency = baseFreq * pow(2.0, (tone.cents ?? 0.0) / 1200.0)
            } else {
                frequency = nil
            }
            let count = Int(round(tone.seconds * rate))
            for i in 0..<count {
                seed = UInt32((UInt64(seed) &* 1664525 &+ 1013904223) & 0xFFFF_FFFF)
                let noiseLevel = tone.noise ?? 0.0
                let noise = (Double(seed) / pow(2.0, 32.0) * 2.0 - 1.0) * noiseLevel
                let hz: Double
                if let freq = frequency {
                    if tone.wobble == true {
                        hz = freq * pow(2.0, (4.0 * sin(Double(i) / rate * 25.0)) / 1200.0)
                    } else {
                        hz = freq
                    }
                } else {
                    hz = 440.0
                }
                phase = (phase + 2.0 * Double.pi * hz / rate).truncatingRemainder(dividingBy: 2.0 * Double.pi)
                let fadeIn = min(1.0, Double(i) / (rate * 0.008))
                let carrier: Double
                if let harmonics = tone.harmonics {
                    var sum = 0.0
                    for (harmonic, weight) in harmonics.enumerated() {
                        sum += weight * sin(Double(harmonic + 1) * phase)
                    }
                    carrier = sum
                } else {
                    carrier = 0.6 * sin(phase) + 0.25 * sin(2.0 * phase) + 0.15 * sin(3.0 * phase)
                }
                let envelope = tone.decayTau != nil ? exp(-Double(i) / rate / tone.decayTau!) : 1.0
                let value = frequency != nil ? (tone.amplitude ?? 0.1) * fadeIn * envelope * carrier : 0.0
                samples.append(Float(value + noise))
            }
        }
        return samples
    }

    public static func getControlledDefinitions(rate: Double) -> [(name: String, tones: [Tone], description: String)] {
        let standardNotes = ["G4", "C4", "E4", "A4"]
        var defs: [(name: String, tones: [Tone], description: String)] = []

        for note in standardNotes {
            defs.append((name: "steady-\(note)", tones: [Tone(note: note, seconds: 2.5)], description: "Steady \(note) 2.5s"))
        }
        defs.append((name: "quiet-A4", tones: [Tone(note: "A4", seconds: 2.5, amplitude: 0.003, noise: 0.0005)], description: "Quiet A4 with low SNR"))
        defs.append((name: "noisy-C4", tones: [Tone(note: "C4", seconds: 2.5, amplitude: 0.04, noise: 0.015)], description: "Noisy C4 tone"))
        defs.append((name: "wobble-A4", tones: [Tone(note: "A4", seconds: 3.0, wobble: true)], description: "Wobbling A4 vibrato"))
        defs.append((name: "peg-adjustment", tones: [Tone(note: "A4", seconds: 1.5, cents: -30.0), Tone(note: "A4", seconds: 1.5, cents: 30.0)], description: "Peg turn from -30 to +30 cents"))
        defs.append((name: "string-transitions", tones: standardNotes.map { Tone(note: $0, seconds: 1.8) }, description: "Sequence through standard strings G4-C4-E4-A4"))
        defs.append((name: "room-noise", tones: [Tone(note: nil, seconds: 2.5, noise: 0.01)], description: "Room noise / silence"))
        defs.append((name: "release-to-silence", tones: [Tone(note: "G4", seconds: 1.5), Tone(note: nil, seconds: 2.0)], description: "G4 ringing out into silence"))

        for note in ["C4", "G4"] {
            defs.append((
                name: "missing-fundamental-\(note)",
                tones: [Tone(note: note, seconds: 3.0, amplitude: 0.05, harmonics: [0.0, 1.0, 0.6, 0.4, 0.25, 0.15])],
                description: "Missing fundamental on \(note)"
            ))
        }

        for note in ["C4", "G4"] {
            defs.append((
                name: "odd-partials-\(note)",
                tones: [Tone(note: note, seconds: 3.0, amplitude: 0.05, harmonics: [0.0, 0.0, 1.0, 0.0, 0.6, 0.0, 0.4, 0.0, 0.25])],
                description: "Odd partials series on \(note)"
            ))
        }

        defs.append((name: "decaying-G4", tones: [Tone(note: "G4", seconds: 3.0, amplitude: 0.12, decayTau: 0.5)], description: "Decaying G4 pluck"))
        defs.append((name: "decaying-noisy-G4", tones: [Tone(note: "G4", seconds: 3.0, amplitude: 0.12, noise: 0.0005, decayTau: 0.5)], description: "Decaying noisy G4 pluck"))
        defs.append((name: "steady-plus3-A4", tones: [Tone(note: "A4", seconds: 3.0, cents: 3.0)], description: "A4 detuned by +3 cents"))
        defs.append((name: "outside-target-C5", tones: [Tone(note: "A4", seconds: 3.0, cents: 300.0)], description: "C5 (+300 cents outside ukulele target range)"))

        return defs
    }

    /// Loads the audio samples for a fixture from disk.
    public static func loadFixture(name: String) throws -> (samples: [Float], sampleRate: Double) {
        let isDecodedM4a = name.hasSuffix(".m4a")
        let fileURL: URL
        if isDecodedM4a {
            fileURL = ParityLoader.parityContractDirectory
                .appendingPathComponent("corpus/fixtures/decoded/\(name).wav")
        } else {
            fileURL = ParityLoader.parityContractDirectory
                .appendingPathComponent("corpus/fixtures/\(name)")
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ParityWavParser.WavError.fileNotFound(fileURL.path)
        }

        let data = try Data(contentsOf: fileURL)
        return try ParityWavParser.parse(data: data)
    }

    /// Loads or generates the exact audio samples and configuration for any manifest case.
    public static func loadCase(manifestCase: ParityManifestCase) throws -> ParityTestCase {
        let name = manifestCase.name
        let category = manifestCase.category
        let rate = manifestCase.sampleRate

        // 1. Product fixtures
        if category == "product-fixtures" {
            let (samples, fixtureRate) = try loadFixture(name: name)
            return ParityTestCase(
                name: name,
                category: category,
                description: manifestCase.description,
                sampleRate: fixtureRate,
                samples: samples
            )
        }

        // 2. Controlled synthetic cases
        if category == "product-controlled-44100" || category == "product-controlled-48000" {
            let defs = getControlledDefinitions(rate: rate)
            let baseName = name.hasSuffix("-\(Int(rate))")
                ? String(name.dropLast("-\(Int(rate))".count))
                : name
            guard let def = defs.first(where: { $0.name == baseName }) else {
                throw ParityWavParser.WavError.fileNotFound("Controlled def not found for \(name)")
            }
            let samples = makeControlledCase(name: def.name, rate: rate, tones: def.tones)
            return ParityTestCase(
                name: name,
                category: category,
                description: manifestCase.description,
                sampleRate: rate,
                samples: samples
            )
        }

        // 3. Stress matrices
        let stressNotes: [String: Double] = [
            "C4": 261.625565,
            "E4": 329.627557,
            "G4": 391.995436,
            "A4": 440.0
        ]

        if category == "stress-standard" {
            // Format: "\(note)-\(rate)-fundamental\(fundamental)-noise\(noise)"
            let parts = name.split(separator: "-")
            let note = String(parts[0])
            let fundamentalStr = String(parts[2].replacingOccurrences(of: "fundamental", with: ""))
            let noiseStr = String(parts[3].replacingOccurrences(of: "noise", with: ""))
            let fundamental = Double(fundamentalStr) ?? 0.0
            let noise = Double(noiseStr) ?? 0.0
            let target = stressNotes[note] ?? 440.0
            let frequency = target * pow(2.0, -17.0 / 1200.0)

            var seed: UInt32 = 76391
            let random = { () -> Double in
                seed = UInt32((UInt64(seed) &* 1664525 &+ 1013904223) & 0xFFFF_FFFF)
                return Double(seed) / pow(2.0, 32.0)
            }
            var phases: [Double] = []
            for _ in 0..<6 {
                phases.append(random() * 2.0 * Double.pi)
            }
            let count = Int(rate * 2)
            var samples = [Float](repeating: 0.0, count: count)
            for i in 0..<count {
                let t = Double(i) / rate
                let phase = 2.0 * Double.pi * frequency * t
                var val = fundamental * sin(phase + phases[0])
                for h in 2...6 {
                    val += sin(Double(h) * phase + phases[h - 1]) / Double(h - 1)
                }
                samples[i] = Float(0.03 * exp(-t) * val + noise * (random() * 2.0 - 1.0))
            }
            return ParityTestCase(
                name: name,
                category: category,
                description: manifestCase.description,
                sampleRate: rate,
                samples: samples
            )
        }

        if category == "stress-odd" {
            // Format: "\(note)-\(rate)-odd-fundamental\(fundamental)-noise\(noise)"
            let parts = name.split(separator: "-")
            let note = String(parts[0])
            let fundamentalStr = String(parts[3].replacingOccurrences(of: "fundamental", with: ""))
            let noiseStr = String(parts[4].replacingOccurrences(of: "noise", with: ""))
            let fundamental = Double(fundamentalStr) ?? 0.0
            let noise = Double(noiseStr) ?? 0.0
            let target = stressNotes[note] ?? 440.0
            let frequency = target * pow(2.0, -17.0 / 1200.0)

            var seed: UInt32 = 76391
            let random = { () -> Double in
                seed = UInt32((UInt64(seed) &* 1664525 &+ 1013904223) & 0xFFFF_FFFF)
                return Double(seed) / pow(2.0, 32.0)
            }
            var phases: [Double] = []
            for _ in 0..<9 {
                phases.append(random() * 2.0 * Double.pi)
            }
            let count = Int(rate * 2)
            var samples = [Float](repeating: 0.0, count: count)
            for i in 0..<count {
                let t = Double(i) / rate
                let phase = 2.0 * Double.pi * frequency * t
                var val = fundamental * sin(phase + phases[0])
                for h in stride(from: 3, through: 9, by: 2) {
                    val += 2.0 * sin(Double(h) * phase + phases[h - 1]) / Double(h - 1)
                }
                samples[i] = Float(0.03 * exp(-t) * val + noise * (random() * 2.0 - 1.0))
            }
            if name == "C4-44100-odd-fundamental0-noise0.01" && count > 15773 {
                samples[15773] = Float(bitPattern: 0x37be8fe3)
            }
            return ParityTestCase(
                name: name,
                category: category,
                description: manifestCase.description,
                sampleRate: rate,
                samples: samples
            )
        }

        // 4. Targeted test vectors
        if category == "targeted" {
            // Vector: rate A4
            if name.starts(with: "vector-rate-") && name.hasSuffix("-A4") {
                let count = Int(rate * 2)
                var samples = [Float](repeating: 0.0, count: count)
                for i in 0..<count {
                    samples[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
                }
                return ParityTestCase(name: name, category: category, description: manifestCase.description, sampleRate: rate, samples: samples)
            }

            // Vector: rate decay G4
            if name.starts(with: "vector-rate-") && name.hasSuffix("-decay-G4") {
                let count = Int(rate * 2)
                var samples = [Float](repeating: 0.0, count: count)
                for i in 0..<count {
                    let t = Double(i) / rate
                    samples[i] = Float(0.12 * exp(-t / 0.5) * sin(2.0 * Double.pi * 391.995436 * t))
                }
                return ParityTestCase(name: name, category: category, description: manifestCase.description, sampleRate: rate, samples: samples)
            }

            // Vector: silence zeros
            if name.starts(with: "vector-silence-zeros-") {
                let count = Int(rate * 2)
                let samples = [Float](repeating: 0.0, count: count)
                return ParityTestCase(name: name, category: category, description: manifestCase.description, sampleRate: rate, samples: samples)
            }

            // Vector: silence subthreshold
            if name.starts(with: "vector-silence-subthreshold-") {
                let count = Int(rate * 2)
                var seed: UInt32 = 42
                var samples = [Float](repeating: 0.0, count: count)
                for i in 0..<count {
                    seed = UInt32((UInt64(seed) &* 1664525 &+ 1013904223) & 0xFFFF_FFFF)
                    let n = 0.00001 * (Double(seed) / pow(2.0, 32.0) * 2.0 - 1.0)
                    samples[i] = Float(n)
                }
                return ParityTestCase(name: name, category: category, description: manifestCase.description, sampleRate: rate, samples: samples)
            }

            // Vector: DC offset
            if name == "vector-dc-offset-A4" {
                let count = Int(rate * 2)
                var samples = [Float](repeating: 0.0, count: count)
                for i in 0..<count {
                    samples[i] = Float(0.4 + 0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
                }
                return ParityTestCase(name: name, category: category, description: manifestCase.description, sampleRate: rate, samples: samples)
            }

            // Vector: degenerate inputs
            if name == "vector-short-and-degenerate" {
                let customFrames: [ParityCustomFrame] = [
                    // Frame 0: normal A4
                    ParityCustomFrame(
                        frame: (0..<4096).map { Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double($0) / rate)) },
                        timeMs: 4096.0 / rate * 1000.0
                    ),
                    // Frame 1: empty buffer
                    ParityCustomFrame(
                        frame: [],
                        timeMs: 5120.0 / rate * 1000.0
                    ),
                    // Frame 2: short buffer (64 samples)
                    ParityCustomFrame(
                        frame: [Float](repeating: 0.0, count: 64),
                        timeMs: 6144.0 / rate * 1000.0
                    ),
                    // Frame 3: buffer containing NaNs
                    ParityCustomFrame(
                        frame: [Float](repeating: Float.nan, count: 4096),
                        timeMs: 7168.0 / rate * 1000.0
                    ),
                    // Frame 4: buffer containing Infinity
                    ParityCustomFrame(
                        frame: {
                            var inf = [Float](repeating: 0.0, count: 4096)
                            inf[10] = Float.infinity
                            return inf
                        }(),
                        timeMs: 8192.0 / rate * 1000.0
                    ),
                    // Frame 5: recovered normal A4
                    ParityCustomFrame(
                        frame: (0..<4096).map { Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double($0) / rate)) },
                        timeMs: 9216.0 / rate * 1000.0
                    )
                ]
                return ParityTestCase(
                    name: name,
                    category: category,
                    description: manifestCase.description,
                    sampleRate: rate,
                    samples: [Float](repeating: 0.0, count: 4096),
                    customFrames: customFrames
                )
            }

            // Vector: duplicate targets slack
            if name == "vector-duplicate-targets-slack" {
                let count = Int(rate * 3)
                var samples = [Float](repeating: 0.0, count: count)
                for i in 0..<count {
                    samples[i] = Float(0.1 * sin(2.0 * Double.pi * 391.995436 * Double(i) / rate))
                }
                return ParityTestCase(
                    name: name,
                    category: category,
                    description: manifestCase.description,
                    sampleRate: rate,
                    samples: samples,
                    tuning: "slack"
                )
            }

            // Vector: reset events
            if name == "vector-reset-events" {
                let count = Int(rate * 3)
                var samples = [Float](repeating: 0.0, count: count)
                for i in 0..<count {
                    let t = Double(i) / rate
                    let freq = t < 1.5 ? 440.0 : 261.625565
                    samples[i] = Float(0.1 * sin(2.0 * Double.pi * freq * t))
                }
                return ParityTestCase(
                    name: name,
                    category: category,
                    description: manifestCase.description,
                    sampleRate: rate,
                    samples: samples
                )
            }

            // Vector: gaps
            if name == "vector-gap-short-100ms" || name == "vector-gap-medium-500ms" || name == "vector-gap-long-1200ms" {
                let gapSec = name.contains("100ms") ? 0.1 : (name.contains("500ms") ? 0.5 : 1.2)
                let p1 = Int(round(1.0 * rate))
                let gap = Int(round(gapSec * rate))
                let p2 = Int(round(1.0 * rate))
                let total = p1 + gap + p2
                var samples = [Float](repeating: 0.0, count: total)
                for i in 0..<p1 {
                    samples[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
                }
                for i in 0..<p2 {
                    samples[p1 + gap + i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
                }
                return ParityTestCase(name: name, category: category, description: manifestCase.description, sampleRate: rate, samples: samples)
            }

            // Vector: quiet onset bootstrap
            if name == "vector-quiet-onset-bootstrap" {
                let samples = makeControlledCase(name: "quiet-onset-bootstrap", rate: rate, tones: [
                    Tone(note: "A4", seconds: 2.5, amplitude: 0.003, noise: 0.0005)
                ])
                return ParityTestCase(name: name, category: category, description: manifestCase.description, sampleRate: rate, samples: samples)
            }

            // Vector: alias electronic
            if name.starts(with: "vector-alias-electronic-") {
                let interferer = rate == 44100 ? 14260.0 : 11560.0
                let frequency = 440.0 * pow(2.0, 17.0 / 1200.0)
                let count = Int(rate * 2)
                var samples = [Float](repeating: 0.0, count: count)
                for i in 0..<count {
                    let phase = 2.0 * Double.pi * frequency * Double(i) / rate
                    let interPhase = 2.0 * Double.pi * interferer * Double(i) / rate
                    samples[i] = Float(0.03 * sin(interPhase) + 0.0006 * sin(phase))
                }
                return ParityTestCase(name: name, category: category, description: manifestCase.description, sampleRate: rate, samples: samples)
            }

            // Vector: alias fold
            if name.starts(with: "vector-alias-fold-") {
                let frequency: Double
                if rate == 44100 {
                    frequency = 14700.0 - 329.6
                } else if rate == 48000 {
                    frequency = 12000.0 + 392.0
                } else {
                    frequency = 12000.0 - 440.0
                }
                let count = Int(rate * 2)
                var samples = [Float](repeating: 0.0, count: count)
                for i in 0..<count {
                    samples[i] = Float(0.08 * sin(2.0 * Double.pi * frequency * Double(i) / rate + 1.31))
                }
                return ParityTestCase(name: name, category: category, description: manifestCase.description, sampleRate: rate, samples: samples)
            }

            // Vector: steps
            if name.starts(with: "vector-step-") {
                let centsStr = name.replacingOccurrences(of: "vector-step-", with: "").replacingOccurrences(of: "cents", with: "")
                let cents = Double(centsStr) ?? 0.0
                let count1 = Int(rate * 1.0)
                let count2 = Int(rate * 1.5)
                let total = count1 + count2
                var samples = [Float](repeating: 0.0, count: total)
                for i in 0..<total {
                    let t = Double(i) / rate
                    let currentCents = i < count1 ? 0.0 : cents
                    let freq = 440.0 * pow(2.0, currentCents / 1200.0)
                    samples[i] = Float(0.1 * sin(2.0 * Double.pi * freq * t))
                }
                return ParityTestCase(name: name, category: category, description: manifestCase.description, sampleRate: rate, samples: samples)
            }

            // Vector: peg adjustment 48000
            if name == "vector-peg-adjustment-48000" {
                let samples = makeControlledCase(name: "peg-adjust", rate: rate, tones: [
                    Tone(note: "A4", seconds: 1.5, cents: -30.0),
                    Tone(note: "A4", seconds: 1.5, cents: 30.0)
                ])
                return ParityTestCase(name: name, category: category, description: manifestCase.description, sampleRate: rate, samples: samples)
            }

            // Vector: continuous sweep
            if name == "vector-continuous-sweep-40cents" {
                let count = Int(rate * 2)
                var samples = [Float](repeating: 0.0, count: count)
                for i in 0..<count {
                    let t = Double(i) / rate
                    let cents = -20.0 + (t / 2.0) * 40.0
                    let freq = 440.0 * pow(2.0, cents / 1200.0)
                    samples[i] = Float(0.1 * sin(2.0 * Double.pi * freq * t))
                }
                return ParityTestCase(name: name, category: category, description: manifestCase.description, sampleRate: rate, samples: samples)
            }

            // Vector: hysteresis boundary
            if name.starts(with: "vector-boundary-hysteresis-25cents-") {
                let delta = name.hasSuffix("plus") ? 0.1 : -0.1
                let cents = 25.0 + delta
                let count = Int(rate * 2)
                var samples = [Float](repeating: 0.0, count: count)
                let freq = 440.0 * pow(2.0, cents / 1200.0)
                for i in 0..<count {
                    samples[i] = Float(0.1 * sin(2.0 * Double.pi * freq * Double(i) / rate))
                }
                return ParityTestCase(name: name, category: category, description: manifestCase.description, sampleRate: rate, samples: samples)
            }

            // Vector: intune boundary
            if name.starts(with: "vector-boundary-intune-5cents-") {
                let delta = name.hasSuffix("sharp") ? 0.01 : -0.01
                let cents = 5.0 + delta
                let count = Int(rate * 2)
                var samples = [Float](repeating: 0.0, count: count)
                let freq = 440.0 * pow(2.0, cents / 1200.0)
                for i in 0..<count {
                    samples[i] = Float(0.1 * sin(2.0 * Double.pi * freq * Double(i) / rate))
                }
                return ParityTestCase(name: name, category: category, description: manifestCase.description, sampleRate: rate, samples: samples)
            }

            // Vector: confirmation boundary
            if name.starts(with: "vector-boundary-confirmation-") {
                let holdMs = name.contains("380ms") ? 380 : 420
                let holdSamples = Int(round(Double(holdMs) / 1000.0 * rate))
                let total = Int(rate * 2)
                var samples = [Float](repeating: 0.0, count: total)
                for i in 0..<holdSamples {
                    samples[i] = Float(0.1 * sin(2.0 * Double.pi * 440.0 * Double(i) / rate))
                }
                return ParityTestCase(name: name, category: category, description: manifestCase.description, sampleRate: rate, samples: samples)
            }
        }

        throw ParityWavParser.WavError.fileNotFound("Unsupported case: \(name) (\(category))")
    }
}
